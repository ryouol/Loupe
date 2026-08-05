import Foundation
import LoupeCore

/// Replays a `<name>.system.ndjson` file of `SystemSample` lines.
public actor ReplayTelemetrySource: TelemetrySource {
    private let fileURL: URL
    public private(set) var droppedLines = 0
    public private(set) var loadFailure: String?

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func stream() -> AsyncStream<SystemSample> {
        guard let blob = try? Data(contentsOf: fileURL) else {
            loadFailure = "Cannot read \(fileURL.path)"
            return AsyncStream { $0.finish() }
        }
        let decoder = JSONDecoder()
        var samples: [SystemSample] = []
        for line in blob.split(separator: UInt8(ascii: "\n")) {
            if let sample = try? decoder.decode(SystemSample.self, from: Data(line)) {
                samples.append(sample)
            } else {
                droppedLines += 1
            }
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

/// Replays a `<name>.ndjson` file of protocol-v1 event lines.
public actor ReplayEventSource {
    private let fileURL: URL
    public private(set) var drops = EventDropCounter()
    public private(set) var loadFailure: String?

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func stream() -> AsyncStream<EventEnvelope> {
        guard let blob = try? Data(contentsOf: fileURL) else {
            loadFailure = "Cannot read \(fileURL.path)"
            return AsyncStream { $0.finish() }
        }
        let decoder = EventLineDecoder()
        var envelopes: [EventEnvelope] = []
        for line in blob.split(separator: UInt8(ascii: "\n")) {
            switch decoder.decode(line: Data(line)) {
            case .success(let envelope): envelopes.append(envelope)
            case .failure(let reason): drops.record(reason)
            }
        }
        let parsed = envelopes
        return AsyncStream { continuation in
            for envelope in parsed {
                continuation.yield(envelope)
            }
            continuation.finish()
        }
    }
}
