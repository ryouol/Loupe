import CryptoKit
import Foundation
import LoupeCore
import LoupeSampler
import Observation

/// Loads a session pair — the headless, testable half of the session screen.
/// Parsing and assembly run off the main actor; only the final assignment
/// touches UI state.
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

    public struct AnnotationRow: Identifiable, Sendable {
        public let id: String
        public let kind: Annotation.Kind
        public let atSeconds: Double
        public let message: String
        public let evidence: Annotation.Evidence
    }

    public private(set) var samples: [SystemSample] = []
    public private(set) var chartPoints: [ChartPoint] = []
    public private(set) var processChartPoints: [ChartPoint] = []
    /// Empty when the session carries no GPU channels — the band hides
    /// entirely rather than charting zeros.
    public private(set) var gpuChartPoints: [ChartPoint] = []
    public private(set) var milestones: [Milestone] = []
    public private(set) var requestMetrics: [RequestMetrics] = []
    public private(set) var annotations: [AnnotationRow] = []
    public private(set) var decodeTickCount = 0
    public private(set) var totalEventCount = 0
    public private(set) var sampleDrops = 0
    public private(set) var eventDrops = 0
    public private(set) var eventSourceSHA256: String?
    public private(set) var telemetrySourceSHA256: String?
    public private(set) var thermalStatesSeen: [ThermalState] = []
    public private(set) var durationSeconds: Double = 0
    public private(set) var isLoaded = false
    public private(set) var loadFailure: String?
    var requestSpans: [TimelineGeometry.RequestSpan] = []
    /// Cached x-values for scrub lookups: readout(at:) runs on every drag
    /// frame and must not re-map 2k points per mouse move.
    private var chartSeconds: [Double] = []
    /// Shared scrubber position; every lane reads this one value, which is
    /// what keeps them aligned by construction.
    public var scrubSeconds: Double?

    public let session: SessionFilePair

    public init(basePath: String) {
        self.session = SessionFilePair(basePath: basePath)
    }

    public func load() async {
        // nonisolated loaders + assembler: the parse work genuinely leaves
        // the main actor, concurrently for the two files.
        async let telemetry = Self.loadTelemetry(from: session.systemURL)
        async let events = Self.loadEvents(from: session.eventsURL)
        let telemetryResult = await telemetry
        let eventsResult = await events
        let assembled = Self.assemble(
            samples: telemetryResult.samples, envelopes: eventsResult.envelopes)

        samples = telemetryResult.samples
        sampleDrops = telemetryResult.drops
        eventDrops = eventsResult.drops
        telemetrySourceSHA256 = telemetryResult.sourceSHA256
        eventSourceSHA256 = eventsResult.sourceSHA256
        chartPoints = assembled.chartPoints
        chartSeconds = assembled.chartPoints.map(\.seconds)
        processChartPoints = assembled.processChartPoints
        gpuChartPoints = assembled.gpuChartPoints
        milestones = assembled.milestones
        requestMetrics = assembled.metrics
        requestSpans = assembled.spans
        annotations = assembled.annotations
        decodeTickCount = assembled.decodeTickCount
        totalEventCount = eventsResult.envelopes.count
        thermalStatesSeen = assembled.thermalStatesSeen
        durationSeconds = assembled.durationSeconds

        loadFailure = telemetryResult.failure ?? eventsResult.failure
        isLoaded = loadFailure == nil
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
        guard let index = TimelineGeometry.nearestIndex(in: chartSeconds, to: seconds)
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

    // MARK: - Loading

    private nonisolated static func loadTelemetry(
        from url: URL
    ) async -> (samples: [SystemSample], drops: Int, failure: String?, sourceSHA256: String?) {
        let data: Data
        do {
            data = try ReplayResourceLimits.read(
                url, maximumBytes: ReplayResourceLimits.maxTelemetryFileBytes)
        } catch {
            return ([], 0, error.localizedDescription, nil)
        }
        let source = ReplayTelemetrySource(data: data, sourceURL: url)
        var samples: [SystemSample] = []
        for await sample in await source.stream() {
            samples.append(sample)
        }
        return (
            samples, await source.droppedLines, await source.loadFailure,
            sourceSHA256(data)
        )
    }

    private nonisolated static func loadEvents(
        from url: URL
    ) async -> (
        envelopes: [EventEnvelope], drops: Int, failure: String?, sourceSHA256: String?
    ) {
        let data: Data
        do {
            data = try ReplayResourceLimits.read(
                url, maximumBytes: ReplayResourceLimits.maxEventFileBytes)
        } catch {
            return ([], 0, error.localizedDescription, nil)
        }
        let source = ReplayEventSource(data: data, sourceURL: url)
        var envelopes: [EventEnvelope] = []
        for await envelope in await source.stream() {
            envelopes.append(envelope)
        }
        return (
            envelopes, await source.drops.total, await source.loadFailure,
            sourceSHA256(data)
        )
    }

    nonisolated static func sourceSHA256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Assembly

    private struct Assembled: Sendable {
        var chartPoints: [ChartPoint] = []
        var processChartPoints: [ChartPoint] = []
        var gpuChartPoints: [ChartPoint] = []
        var milestones: [Milestone] = []
        var metrics: [RequestMetrics] = []
        var spans: [TimelineGeometry.RequestSpan] = []
        var annotations: [AnnotationRow] = []
        var decodeTickCount = 0
        var thermalStatesSeen: [ThermalState] = []
        var durationSeconds: Double = 0
    }

    /// Series cap per the M2.1 spec: LTTB to ~2k points keeps charts honest
    /// (spikes survive) and rendering cheap on hour-long sessions.
    private nonisolated static let maxChartPoints = 2_000

    private nonisolated static func assemble(
        samples: [SystemSample], envelopes: [EventEnvelope]
    ) -> Assembled {
        var assembled = Assembled()

        // Adapter clocks map onto the sample clock once, up front (min-RTT
        // clock_sync estimate; 0 for same-machine adapters). Every consumer
        // below — milestones, metrics, spans, annotations — sees sample-clock
        // events, so nothing downstream needs to know which rule derived a
        // timestamp from a sample versus an event.
        let offset = TimelineMerge.offset(fromClockSyncEvents: envelopes)
        let unifiedEnvelopes =
            offset == 0
            ? envelopes
            : envelopes.map { envelope in
                EventEnvelope(
                    ts: TimelineMerge.shifted(envelope.ts, byRemovingOffset: offset),
                    runId: envelope.runId,
                    requestId: envelope.requestId,
                    payload: envelope.payload)
            }
        let zeroTs = min(
            samples.first?.system.ts ?? UInt64.max,
            unifiedEnvelopes.first?.ts ?? UInt64.max)
        guard zeroTs != UInt64.max else { return assembled }
        func seconds(_ ts: UInt64) -> Double {
            Double(ts &- zeroTs) / 1e9
        }

        let allPoints = samples.enumerated().map { index, sample in
            ChartPoint(
                id: index,
                seconds: seconds(sample.system.ts),
                systemUsedGB: Double(sample.system.memoryUsedBytes) / 1e9,
                swapUsedGB: Double(sample.system.swapUsedBytes) / 1e9,
                processRSSGB: sample.process.map { Double($0.rssBytes) / 1e9 },
                gpuBusyPercent: sample.system.gpuBusyPercent,
                packagePowerWatts: sample.system.packagePowerMilliwatts.map { $0 / 1_000 })
        }
        assembled.chartPoints = Downsample.lttb(
            allPoints, to: maxChartPoints, x: { $0.seconds }, y: { $0.systemUsedGB })
        assembled.processChartPoints = assembled.chartPoints.filter { $0.processRSSGB != nil }
        assembled.gpuChartPoints = assembled.chartPoints.filter {
            $0.gpuBusyPercent != nil || $0.packagePowerWatts != nil
        }

        for envelope in unifiedEnvelopes {
            if envelope.kind == .decodeTick {
                assembled.decodeTickCount += 1
                continue
            }
            assembled.milestones.append(
                Milestone(
                    id: assembled.milestones.count,
                    offsetSeconds: seconds(envelope.ts),
                    kind: envelope.kind,
                    requestId: envelope.requestId,
                    detail: describe(envelope.payload)))
        }

        assembled.metrics = SessionMetrics.perRequest(events: unifiedEnvelopes)
        assembled.spans = TimelineGeometry.requestSpans(
            metrics: assembled.metrics, milestones: assembled.milestones)
        assembled.annotations = AnnotationEngine.annotate(
            samples: samples, events: unifiedEnvelopes, metrics: assembled.metrics
        )
        .map { annotation in
            AnnotationRow(
                id: annotation.id,
                kind: annotation.kind,
                atSeconds: seconds(annotation.atNs),
                message: annotation.message,
                evidence: annotation.evidence)
        }
        assembled.thermalStatesSeen = Set(samples.map(\.system.thermalState)).sorted()
        assembled.durationSeconds = max(
            assembled.chartPoints.last?.seconds ?? 0,
            assembled.milestones.last?.offsetSeconds ?? 0)
        return assembled
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
