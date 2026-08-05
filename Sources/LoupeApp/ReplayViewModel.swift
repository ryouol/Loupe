import Foundation
import LoupeCore
import LoupeSampler
import Observation

/// Loads a session pair — the headless, testable half of the session screen.
/// Parsing runs off the main actor; only the final assignment touches UI
/// state.
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
    public private(set) var chartPoints: [ChartPoint] = []
    public private(set) var processChartPoints: [ChartPoint] = []
    public private(set) var milestones: [Milestone] = []
    public private(set) var decodeTickCount = 0
    public private(set) var totalEventCount = 0
    public private(set) var sampleDrops = 0
    public private(set) var eventDrops = 0
    public private(set) var thermalStatesSeen: [ThermalState] = []
    public private(set) var isLoaded = false
    public private(set) var loadFailure: String?

    public let session: SessionFilePair

    public init(basePath: String) {
        self.session = SessionFilePair(basePath: basePath)
    }

    public func load() async {
        // nonisolated static loaders: the parse work genuinely leaves the
        // main actor, concurrently for the two files.
        async let telemetry = Self.loadTelemetry(from: session.systemURL)
        async let events = Self.loadEvents(from: session.eventsURL)
        let telemetryResult = await telemetry
        let eventsResult = await events

        samples = telemetryResult.samples
        chartPoints = telemetryResult.chartPoints
        processChartPoints = telemetryResult.processChartPoints
        sampleDrops = telemetryResult.drops
        thermalStatesSeen = Set(telemetryResult.samples.map(\.system.thermalState)).sorted()

        milestones = eventsResult.milestones
        decodeTickCount = eventsResult.decodeTicks
        totalEventCount = eventsResult.total
        eventDrops = eventsResult.drops

        loadFailure = telemetryResult.failure ?? eventsResult.failure
        isLoaded = loadFailure == nil
    }

    private nonisolated static func loadTelemetry(
        from url: URL
    ) async -> (
        samples: [SystemSample], chartPoints: [ChartPoint], processChartPoints: [ChartPoint],
        drops: Int, failure: String?
    ) {
        let source = ReplayTelemetrySource(fileURL: url)
        var samples: [SystemSample] = []
        for await sample in await source.stream() {
            samples.append(sample)
        }
        let points = chartPoints(from: samples)
        return (
            samples, points, points.filter { $0.processRSSGB != nil },
            await source.droppedLines, await source.loadFailure
        )
    }

    private nonisolated static func loadEvents(
        from url: URL
    ) async -> (milestones: [Milestone], decodeTicks: Int, total: Int, drops: Int, failure: String?)
    {
        let source = ReplayEventSource(fileURL: url)
        var milestones: [Milestone] = []
        var ticks = 0
        var total = 0
        var firstTs: UInt64?
        for await envelope in await source.stream() {
            total += 1
            if firstTs == nil { firstTs = envelope.ts }
            // Per-token ticks are kept as a count; the table shows phases.
            if envelope.kind == .decodeTick {
                ticks += 1
                continue
            }
            milestones.append(
                Milestone(
                    id: milestones.count,
                    offsetSeconds: Double(envelope.ts &- (firstTs ?? envelope.ts)) / 1e9,
                    kind: envelope.kind,
                    requestId: envelope.requestId,
                    detail: describe(envelope.payload)))
        }
        return (milestones, ticks, total, await source.drops.total, await source.loadFailure)
    }

    private nonisolated static func chartPoints(from samples: [SystemSample]) -> [ChartPoint] {
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

    private nonisolated static func describe(_ payload: EventPayload) -> String {
        switch payload {
        case .sessionStart(let p):
            return "\(p.adapter) \(p.adapterVersion) · \(p.runtime) · pid \(p.pid)"
        case .clockSync(let p):
            let estimate = p.sample.estimate()
            return "offset \(estimate.map { "\($0.offsetNs) ns" } ?? "invalid")"
        case .modelLoadStart(let p):
            return p.modelId
        case .modelLoadEnd(let p):
            let size = p.weightsBytes.map { " · \(formattedBytes($0))" } ?? ""
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
