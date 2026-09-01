import Darwin
import Foundation
import LoupeCore
import LoupeTelemetry

public enum ReplayResourceLimits {
    public static let maxEventFileBytes = 64 * 1_024 * 1_024
    public static let maxTelemetryFileBytes = 128 * 1_024 * 1_024
    public static let maxEvents = 500_000
    public static let maxSamples = 100_000

    public static func read(_ url: URL, maximumBytes: Int) throws -> Data {
        guard maximumBytes > 0 else {
            throw ReplayFileError.fileTooLarge(url.path, maximumBytes)
        }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw ReplayFileError.notRegularFile(url.path)
        }
        defer { close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
            metadata.st_mode & S_IFMT == S_IFREG
        else { throw ReplayFileError.notRegularFile(url.path) }
        guard metadata.st_size >= 0, metadata.st_size <= off_t(maximumBytes) else {
            throw ReplayFileError.fileTooLarge(url.path, maximumBytes)
        }

        var data = Data()
        data.reserveCapacity(Int(metadata.st_size))
        while true {
            // Read one byte past the boundary to detect a file that grew
            // after fstat without ever allocating its unbounded new size.
            var buffer = [UInt8](
                repeating: 0, count: min(65_536, maximumBytes - data.count + 1))
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 { return data }
            if count < 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            guard data.count <= maximumBytes - count else {
                throw ReplayFileError.fileTooLarge(url.path, maximumBytes)
            }
            data.append(contentsOf: buffer.prefix(count))
        }
    }
}

public enum ReplayFileError: LocalizedError, Equatable {
    case notRegularFile(String)
    case fileTooLarge(String, Int)
    case tooManyRows(String, Int)
    case nonMonotonicTimestamps(String)
    case unalignedProcessTimestamp(String)
    case mixedRunIdentifiers(String)
    case invalidEventSequence(String)
    case invalidTelemetryRows(String)

    public var errorDescription: String? {
        switch self {
        case .notRegularFile(let path): return "Replay input is not a regular file: \(path)"
        case .fileTooLarge(let path, let maximum):
            return "Replay input exceeds the \(maximum)-byte limit: \(path)"
        case .tooManyRows(let path, let maximum):
            return "Replay input exceeds the \(maximum)-row limit: \(path)"
        case .nonMonotonicTimestamps(let path):
            return "Replay timestamps are not monotonic: \(path)"
        case .unalignedProcessTimestamp(let path):
            return "Replay process and system timestamps are not aligned: \(path)"
        case .mixedRunIdentifiers(let path):
            return "Replay event input contains multiple run identifiers: \(path)"
        case .invalidEventSequence(let path):
            return "Replay runtime events do not form a valid session sequence: \(path)"
        case .invalidTelemetryRows(let path):
            return "Replay telemetry contains no valid sample rows: \(path)"
        }
    }
}

/// Replays a `<name>.system.ndjson` file of `SystemSample` lines.
public actor ReplayTelemetrySource: TelemetrySource {
    private let fileURL: URL
    private let preloadedData: Data?
    public private(set) var droppedLines = 0
    public private(set) var loadFailure: String?

    public init(fileURL: URL) {
        self.fileURL = fileURL
        self.preloadedData = nil
    }

    /// Parses an immutable caller-owned snapshot. Evidence exporters use
    /// this path so displayed metrics and the recorded source digest are
    /// derived from the exact same bytes.
    public init(data: Data, sourceURL: URL) {
        self.fileURL = sourceURL
        self.preloadedData = data
    }

    public func stream() -> AsyncStream<SystemSample> {
        droppedLines = 0
        loadFailure = nil
        let blob: Data
        do {
            if let preloadedData {
                guard preloadedData.count <= ReplayResourceLimits.maxTelemetryFileBytes else {
                    throw ReplayFileError.fileTooLarge(
                        fileURL.path, ReplayResourceLimits.maxTelemetryFileBytes)
                }
                blob = preloadedData
            } else {
                blob = try ReplayResourceLimits.read(
                    fileURL, maximumBytes: ReplayResourceLimits.maxTelemetryFileBytes)
            }
        } catch {
            loadFailure = error.localizedDescription
            return AsyncStream { $0.finish() }
        }
        var samples: [SystemSample] = []
        var rowCount = 0
        var lastTimestamp: UInt64?
        var lastAcquisitionSequence: UInt64?
        var sawLegacySequence = false
        var sawVersionedSequence = false
        for line in blob.split(separator: UInt8(ascii: "\n")) {
            rowCount += 1
            guard rowCount <= ReplayResourceLimits.maxSamples else {
                loadFailure =
                    ReplayFileError.tooManyRows(
                        fileURL.path, ReplayResourceLimits.maxSamples
                    ).localizedDescription
                return AsyncStream { $0.finish() }
            }
            if line.count <= EventLineDecoder.maxLineBytes,
                let sample = SystemSampleWireDecoder.decode(Data(line))
            {
                if let sequence = sample.acquisitionSequence {
                    guard !sawLegacySequence,
                        lastAcquisitionSequence.map({ sequence > $0 }) ?? true
                    else {
                        droppedLines += 1
                        continue
                    }
                    sawVersionedSequence = true
                    lastAcquisitionSequence = sequence
                } else {
                    guard !sawVersionedSequence else {
                        droppedLines += 1
                        continue
                    }
                    sawLegacySequence = true
                }
                guard lastTimestamp.map({ sample.system.ts >= $0 }) ?? true else {
                    loadFailure =
                        ReplayFileError.nonMonotonicTimestamps(
                            fileURL.path
                        ).localizedDescription
                    return AsyncStream { $0.finish() }
                }
                guard sample.process.map({ $0.ts == sample.system.ts }) ?? true else {
                    loadFailure =
                        ReplayFileError.unalignedProcessTimestamp(
                            fileURL.path
                        ).localizedDescription
                    return AsyncStream { $0.finish() }
                }
                samples.append(sample)
                lastTimestamp = sample.system.ts
            } else {
                droppedLines += 1
            }
        }
        // A genuinely empty telemetry file is a valid event-only session.
        // A non-empty file whose every row was rejected is corruption, not
        // an empty trace that the UI should quietly certify as loaded.
        guard !samples.isEmpty || droppedLines == 0 else {
            loadFailure = ReplayFileError.invalidTelemetryRows(fileURL.path).localizedDescription
            return AsyncStream { $0.finish() }
        }
        let parsed = samples
        return AsyncStream { continuation in
            for sample in parsed {
                continuation.yield(sample)
            }
            continuation.finish()
        }
    }
}

/// Replays a `<name>.ndjson` file of protocol-v3 or compatible v1/v2 event lines.
public actor ReplayEventSource {
    private let fileURL: URL
    private let preloadedData: Data?
    public private(set) var drops = EventDropCounter()
    public private(set) var loadFailure: String?

    public init(fileURL: URL) {
        self.fileURL = fileURL
        self.preloadedData = nil
    }

    /// Parses an immutable caller-owned snapshot; see the telemetry source.
    public init(data: Data, sourceURL: URL) {
        self.fileURL = sourceURL
        self.preloadedData = data
    }

    public func stream() -> AsyncStream<EventEnvelope> {
        drops = EventDropCounter()
        loadFailure = nil
        let blob: Data
        do {
            if let preloadedData {
                guard preloadedData.count <= ReplayResourceLimits.maxEventFileBytes else {
                    throw ReplayFileError.fileTooLarge(
                        fileURL.path, ReplayResourceLimits.maxEventFileBytes)
                }
                blob = preloadedData
            } else {
                blob = try ReplayResourceLimits.read(
                    fileURL, maximumBytes: ReplayResourceLimits.maxEventFileBytes)
            }
        } catch {
            loadFailure = error.localizedDescription
            return AsyncStream { $0.finish() }
        }
        guard blob.split(separator: UInt8(ascii: "\n")).count <= ReplayResourceLimits.maxEvents
        else {
            loadFailure =
                ReplayFileError.tooManyRows(
                    fileURL.path, ReplayResourceLimits.maxEvents
                ).localizedDescription
            return AsyncStream { $0.finish() }
        }
        let (parsed, dropped) = EventLineDecoder().decodeLines(blob)
        drops = dropped
        guard Set(parsed.map(\.runId)).count <= 1 else {
            loadFailure = ReplayFileError.mixedRunIdentifiers(fileURL.path).localizedDescription
            return AsyncStream { $0.finish() }
        }
        guard zip(parsed, parsed.dropFirst()).allSatisfy({ pair in pair.0.ts <= pair.1.ts }) else {
            loadFailure =
                ReplayFileError.nonMonotonicTimestamps(
                    fileURL.path
                ).localizedDescription
            return AsyncStream { $0.finish() }
        }
        var streamValidator = EventStreamValidator()
        guard parsed.allSatisfy({ streamValidator.accepts($0) }),
            parsed.isEmpty ? dropped.total == 0 : streamValidator.hasStartedSession
        else {
            loadFailure = ReplayFileError.invalidEventSequence(fileURL.path).localizedDescription
            return AsyncStream { $0.finish() }
        }
        return AsyncStream { continuation in
            for envelope in parsed {
                continuation.yield(envelope)
            }
            continuation.finish()
        }
    }
}
