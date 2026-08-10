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
        public let gpuBusyPercent: Double?
        public let packagePowerWatts: Double?
    }

    public private(set) var samples: [SystemSample] = []
    public private(set) var chartPoints: [ChartPoint] = []
    public private(set) var processChartPoints: [ChartPoint] = []
    /// Empty when the session carries no GPU channels — the band hides
    /// entirely rather than charting zeros.
    public private(set) var gpuChartPoints: [ChartPoint] = []
    public private(set) var durationSeconds: Double = 0
    var requestSpans: [TimelineGeometry.RequestSpan] = []
    /// Shared scrubber position; every lane reads this one value, which is
    /// what keeps them aligned by construction.
    public var scrubSeconds: Double?
    public private(set) var milestones: [Milestone] = []
    public private(set) var requestMetrics: [RequestMetrics] = []
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
        gpuChartPoints = chartPoints.filter {
            $0.gpuBusyPercent != nil || $0.packagePowerWatts != nil
        }
        durationSeconds = chartPoints.last?.seconds ?? 0
        sampleDrops = telemetryResult.drops
        thermalStatesSeen = Set(telemetryResult.samples.map(\.system.thermalState)).sorted()

        milestones = eventsResult.milestones
        requestMetrics = eventsResult.metrics
        decodeTickCount = eventsResult.decodeTicks
        totalEventCount = eventsResult.total
        eventDrops = eventsResult.drops
        requestSpans = TimelineGeometry.requestSpans(
            metrics: eventsResult.metrics, milestones: eventsResult.milestones)

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
    ) async -> (
        milestones: [Milestone], metrics: [RequestMetrics], decodeTicks: Int, total: Int,
        drops: Int, failure: String?
    ) {
        let source = ReplayEventSource(fileURL: url)
        var milestones: [Milestone] = []
        var envelopes: [EventEnvelope] = []
        var ticks = 0
        var firstTs: UInt64?
        for await envelope in await source.stream() {
            envelopes.append(envelope)
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
        return (
            milestones, SessionMetrics.perRequest(events: envelopes), ticks, envelopes.count,
            await source.drops.total, await source.loadFailure
        )
    }

    /// Series cap per the M2.1 spec: LTTB to ~2k points keeps charts honest
    /// (spikes survive) and rendering cheap on hour-long sessions.
    private nonisolated static let maxChartPoints = 2_000

    private nonisolated static func chartPoints(from samples: [SystemSample]) -> [ChartPoint] {
        guard let first = samples.first?.system.ts else { return [] }
        let all = samples.enumerated().map { index, sample in
            ChartPoint(
                id: index,
                seconds: Double(sample.system.ts &- first) / 1e9,
                systemUsedGB: Double(sample.system.memoryUsedBytes) / 1e9,
                swapUsedGB: Double(sample.system.swapUsedBytes) / 1e9,
                processRSSGB: sample.process.map { Double($0.rssBytes) / 1e9 },
                gpuBusyPercent: sample.system.gpuBusyPercent,
                packagePowerWatts: sample.system.packagePowerMilliwatts.map { $0 / 1_000 })
        }
        return Downsample.lttb(
            all, to: maxChartPoints, x: { $0.seconds }, y: { $0.systemUsedGB })
    }

    // MARK: - Scrubbing

    public struct ScrubReadout: Equatable {
        public let seconds: Double
        public let systemUsedGB: Double
        public let swapUsedGB: Double
        public let processRSSGB: Double?
        public let gpuBusyPercent: Double?
        public let activeRequestId: String?
    }

    /// Everything the readout shows comes from one scrub position resolved
    /// against one point index — the alignment tests pin this.
    public func readout(at seconds: Double) -> ScrubReadout? {
        guard
            let index = TimelineGeometry.nearestIndex(
                in: chartPoints.map(\.seconds), to: seconds)
        else { return nil }
        let point = chartPoints[index]
        return ScrubReadout(
            seconds: point.seconds,
            systemUsedGB: point.systemUsedGB,
            swapUsedGB: point.swapUsedGB,
            processRSSGB: point.processRSSGB,
            gpuBusyPercent: point.gpuBusyPercent,
            activeRequestId: TimelineGeometry.activeSpan(in: requestSpans, at: seconds)?.id)
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
