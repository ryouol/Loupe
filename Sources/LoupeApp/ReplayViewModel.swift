import Foundation
import LoupeCore
import LoupeSampler
import Observation

/// Loads a session pair (`<base>.ndjson` + `<base>.system.ndjson`) — the
/// headless, testable half of the session screen.
@MainActor
@Observable
public final class ReplayViewModel {
    public struct Milestone: Identifiable, Sendable {
        public let id: Int
        public let offsetSeconds: Double
        public let kind: EventKind
        public let requestId: String?
        public let detail: String
    }

    public struct ChartPoint: Identifiable, Sendable {
        public let id: Int
        public let seconds: Double
        public let systemUsedGB: Double
        public let swapUsedGB: Double
        public let processRSSGB: Double?
    }

    public private(set) var samples: [SystemSample] = []
    public private(set) var milestones: [Milestone] = []
    public private(set) var decodeTickCount = 0
    public private(set) var totalEventCount = 0
    public private(set) var sampleDrops = 0
    public private(set) var eventDrops = 0
    public private(set) var thermalStatesSeen: [ThermalState] = []
    public private(set) var isLoaded = false
    public private(set) var loadFailure: String?

    public let basePath: String

    public init(basePath: String) {
        self.basePath = basePath
    }

    public var chartPoints: [ChartPoint] {
        guard let first = samples.first?.system.ts else { return [] }
        return samples.enumerated().map { index, sample in
            ChartPoint(
                id: index,
                seconds: Double(sample.system.ts &- first) / 1e9,
                systemUsedGB: Double(sample.system.memoryUsedBytes) / 1e9,
                swapUsedGB: Double(sample.system.swapUsedBytes) / 1e9,
                processRSSGB: sample.process.map { Double($0.rssBytes) / 1e9 })
        }
    }

    public var summary: String {
        guard isLoaded else { return loadFailure ?? "Loading fixture…" }
        return "\(samples.count) system samples · \(totalEventCount) events "
            + "(\(decodeTickCount) decode ticks) · dropped \(sampleDrops)+\(eventDrops)"
    }

    public func load() async {
        let systemURL = URL(fileURLWithPath: basePath + ".system.ndjson")
        let eventsURL = URL(fileURLWithPath: basePath + ".ndjson")

        let telemetry = ReplayTelemetrySource(fileURL: systemURL)
        var collected: [SystemSample] = []
        for await sample in await telemetry.stream() {
            collected.append(sample)
        }
        samples = collected
        sampleDrops = await telemetry.droppedLines
        let telemetryFailure = await telemetry.loadFailure

        let events = ReplayEventSource(fileURL: eventsURL)
        var rows: [Milestone] = []
        var ticks = 0
        var total = 0
        var firstTs: UInt64?
        for await envelope in await events.stream() {
            total += 1
            if firstTs == nil { firstTs = envelope.ts }
            // Per-token ticks are kept as a count; the table shows phases.
            if envelope.kind == .decodeTick {
                ticks += 1
                continue
            }
            rows.append(
                Milestone(
                    id: rows.count,
                    offsetSeconds: Double(envelope.ts &- (firstTs ?? envelope.ts)) / 1e9,
                    kind: envelope.kind,
                    requestId: envelope.requestId,
                    detail: Self.describe(envelope.payload)))
        }
        milestones = rows
        decodeTickCount = ticks
        totalEventCount = total
        eventDrops = await events.drops.total
        let eventsFailure = await events.loadFailure

        thermalStatesSeen = Set(samples.map(\.system.thermalState)).sorted()
        loadFailure = telemetryFailure ?? eventsFailure
        isLoaded = loadFailure == nil
    }

    private static func describe(_ payload: EventPayload) -> String {
        switch payload {
        case .sessionStart(let p):
            return "\(p.adapter) \(p.adapterVersion) · \(p.runtime) · pid \(p.pid)"
        case .clockSync(let p):
            let estimate = p.sample.estimate()
            let offset = estimate.map { "\($0.offsetNs) ns" } ?? "invalid"
            return "offset \(offset)"
        case .modelLoadStart(let p):
            return p.modelId
        case .modelLoadEnd(let p):
            let size =
                p.weightsBytes.map {
                    " · \(ByteCountFormatter.string(fromByteCount: Int64(clamping: $0), countStyle: .memory))"
                } ?? ""
            return "\(p.modelId) · \(p.ok ? "ok" : "FAILED")\(size)"
        case .requestStart(let p):
            return p.promptTokens.map { "\($0) prompt tokens" } ?? "started"
        case .prefillEnd(let p):
            return "\(p.promptTokens) prompt tokens"
        case .decodeTick(let p):
            return "\(p.outputTokens) tokens"
        case .requestEnd(let p):
            return "\(p.outputTokens) tokens · \(p.finishReason)"
        case .error(let p):
            return "\(p.code): \(p.message)"
        }
    }
}
