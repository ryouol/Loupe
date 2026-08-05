import Foundation
import LoupeCore

public enum ReplayPacing: Sendable {
    case immediate
    /// Sleep out the recorded timestamp gaps.
    case realtime
}

/// Replays a `<name>.system.ndjson` file of `SystemSample` lines.
public actor ReplayTelemetrySource: TelemetrySource {
    /// Gap cap so a damaged fixture cannot hang realtime replay.
    private static let maxRealtimeGapNs: UInt64 = 1_000_000_000

    private let fileURL: URL
    private let pacing: ReplayPacing
    public private(set) var droppedLines = 0
    public private(set) var loadFailure: String?

    public init(fileURL: URL, pacing: ReplayPacing = .immediate) {
        self.fileURL = fileURL
        self.pacing = pacing
    }

    public func stream() -> AsyncStream<SystemSample> {
        let blob: Data
        do {
            blob = try Data(contentsOf: fileURL)
        } catch {
            loadFailure = error.localizedDescription
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

        let pacing = self.pacing
        let parsed = samples
        return AsyncStream { continuation in
            let task = Task {
                var previousTs: UInt64?
                for sample in parsed {
                    if Task.isCancelled { break }
                    if case .realtime = pacing, let previous = previousTs,
                        sample.system.ts > previous
                    {
                        let gap = min(sample.system.ts - previous, Self.maxRealtimeGapNs)
                        try? await Task.sleep(nanoseconds: gap)
                    }
                    previousTs = sample.system.ts
                    continuation.yield(sample)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Replays a `<name>.ndjson` file of protocol-v1 event lines.
public actor ReplayEventSource {
    private let fileURL: URL
    private let pacing: ReplayPacing
    public private(set) var drops = EventDropCounter()
    public private(set) var loadFailure: String?

    public init(fileURL: URL, pacing: ReplayPacing = .immediate) {
        self.fileURL = fileURL
        self.pacing = pacing
    }

    public func stream() -> AsyncStream<EventEnvelope> {
        let blob: Data
        do {
            blob = try Data(contentsOf: fileURL)
        } catch {
            loadFailure = error.localizedDescription
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

        let pacing = self.pacing
        let parsed = envelopes
        return AsyncStream { continuation in
            let task = Task {
                var previousTs: UInt64?
                for envelope in parsed {
                    if Task.isCancelled { break }
                    if case .realtime = pacing, let previous = previousTs,
                        envelope.ts > previous
                    {
                        let gap = min(envelope.ts - previous, 1_000_000_000)
                        try? await Task.sleep(nanoseconds: gap)
                    }
                    previousTs = envelope.ts
                    continuation.yield(envelope)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
