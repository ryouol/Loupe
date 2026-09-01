import CryptoKit
import Darwin
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
        public let processCPUPercent: Double?
        public let gpuBusyPercent: Double?
        public let gpuPowerWatts: Double?
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
    public private(set) var gpuPowerChartPoints: [ChartPoint] = []
    public private(set) var packagePowerChartPoints: [ChartPoint] = []
    public private(set) var milestones: [Milestone] = []
    public private(set) var requestMetrics: [RequestMetrics] = []
    public private(set) var annotations: [AnnotationRow] = []
    public private(set) var decodeTickCount = 0
    public private(set) var totalEventCount = 0
    public private(set) var sampleDrops = 0
    public private(set) var eventDrops = 0
    public private(set) var eventSourceSHA256: String?
    public private(set) var telemetrySourceSHA256: String?
    public private(set) var acquisitionSourceSHA256: String?
    public private(set) var acquisitionMetadata: SessionAcquisitionMetadata?
    public private(set) var thermalStatesSeen: [ThermalState] = []
    public private(set) var durationSeconds: Double = 0
    public private(set) var isLoaded = false
    public private(set) var loadFailure: String?
    var requestSpans: [TimelineGeometry.RequestSpan] = []
    private var samplePoints: [ChartPoint] = []
    private var sampleSeconds: [Double] = []
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
        async let metadata = Self.loadAcquisitionMetadata(from: session.metadataURL)
        let telemetryResult = await telemetry
        let eventsResult = await events
        let metadataResult = await metadata
        let assembled = Self.assemble(
            samples: telemetryResult.samples, envelopes: eventsResult.envelopes)

        samples = telemetryResult.samples
        sampleDrops = telemetryResult.drops
        eventDrops = eventsResult.drops
        telemetrySourceSHA256 = telemetryResult.sourceSHA256
        eventSourceSHA256 = eventsResult.sourceSHA256
        acquisitionMetadata = metadataResult.metadata
        acquisitionSourceSHA256 = metadataResult.sourceSHA256
        chartPoints = assembled.chartPoints
        samplePoints = assembled.samplePoints
        sampleSeconds = assembled.samplePoints.map(\.seconds)
        processChartPoints = assembled.processChartPoints
        gpuChartPoints = assembled.gpuChartPoints
        gpuPowerChartPoints = assembled.gpuPowerChartPoints
        packagePowerChartPoints = assembled.packagePowerChartPoints
        milestones = assembled.milestones
        requestMetrics = assembled.metrics
        requestSpans = assembled.spans
        annotations = assembled.annotations
        decodeTickCount = assembled.decodeTickCount
        totalEventCount = eventsResult.envelopes.count
        thermalStatesSeen = assembled.thermalStatesSeen
        durationSeconds = assembled.durationSeconds

        loadFailure = telemetryResult.failure ?? eventsResult.failure ?? metadataResult.failure
        isLoaded = loadFailure == nil
    }

    // MARK: - Scrubbing

    public struct ScrubReadout: Equatable {
        public let seconds: Double
        public let systemUsedGB: Double
        public let swapUsedGB: Double
        public let processRSSGB: Double?
        public let processCPUPercent: Double?
        public let gpuBusyPercent: Double?
        public let gpuPowerWatts: Double?
        public let packagePowerWatts: Double?
        public let activeRequestId: String?
    }

    /// Everything the readout shows comes from one scrub position resolved
    /// against one point index — the alignment tests pin this.
    public func readout(at seconds: Double) -> ScrubReadout? {
        guard let index = TimelineGeometry.nearestIndex(in: sampleSeconds, to: seconds)
        else { return nil }
        let point = samplePoints[index]
        return ScrubReadout(
            seconds: point.seconds,
            systemUsedGB: point.systemUsedGB,
            swapUsedGB: point.swapUsedGB,
            processRSSGB: point.processRSSGB,
            processCPUPercent: point.processCPUPercent,
            gpuBusyPercent: point.gpuBusyPercent,
            gpuPowerWatts: point.gpuPowerWatts,
            packagePowerWatts: point.packagePowerWatts,
            activeRequestId: TimelineGeometry.activeSpan(in: requestSpans, at: seconds)?.id)
    }

    public var acquisitionLossDisplay: String {
        guard let acquisitionMetadata else { return "unknown" }
        let event = acquisitionMetadata.eventLosses
        let telemetry = acquisitionMetadata.telemetryLosses
        if let eventExact = event.exact, let telemetryExact = telemetry.exact {
            return String(Self.saturatingSum(eventExact, telemetryExact))
        }
        let observed = Self.saturatingSum(event.lowerBound, telemetry.lowerBound)
        return observed == 0 ? "unknown" : "≥\(observed) · unknown total"
    }

    public var memoryAccessibilitySummary: String {
        Self.rangeSummary(
            chartPoints.map(\.systemUsedGB), unit: "GB memory",
            count: chartPoints.count)
    }

    public var processMemoryAccessibilitySummary: String {
        Self.rangeSummary(
            processChartPoints.compactMap(\.processRSSGB), unit: "GB RSS",
            count: processChartPoints.count)
    }

    public var processCPUAccessibilitySummary: String {
        Self.rangeSummary(
            processChartPoints.compactMap(\.processCPUPercent), unit: "percent CPU",
            count: processChartPoints.count)
    }

    public var gpuUtilizationAccessibilitySummary: String {
        Self.rangeSummary(
            gpuChartPoints.compactMap(\.gpuBusyPercent), unit: "percent GPU busy",
            count: gpuChartPoints.count)
    }

    public var powerAccessibilitySummary: String {
        let values =
            gpuPowerChartPoints.compactMap(\.gpuPowerWatts)
            + packagePowerChartPoints.compactMap(\.packagePowerWatts)
        return Self.rangeSummary(
            values, unit: "watts",
            count: max(
                gpuPowerChartPoints.count, packagePowerChartPoints.count))
    }

    private nonisolated static func rangeSummary(
        _ values: [Double], unit: String, count: Int
    ) -> String {
        guard let minimum = values.min(), let maximum = values.max() else {
            return "Unavailable"
        }
        return String(
            format: "%d plotted samples; %.2f to %.2f %@",
            locale: Locale(identifier: "en_US_POSIX"), count, minimum, maximum, unit)
    }

    private nonisolated static func saturatingSum(_ lhs: Int, _ rhs: Int) -> Int {
        lhs > Int.max - rhs ? Int.max : lhs + rhs
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

    private nonisolated static func loadAcquisitionMetadata(
        from url: URL
    ) async -> (
        metadata: SessionAcquisitionMetadata?, failure: String?, sourceSHA256: String?
    ) {
        var node = stat()
        if lstat(url.path, &node) != 0, errno == ENOENT {
            return (nil, nil, nil)
        }
        do {
            let data = try ReplayResourceLimits.read(url, maximumBytes: 65_536)
            guard
                let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                Set(root.keys) == ["schemaVersion", "eventLosses", "telemetryLosses"],
                let event = root["eventLosses"] as? [String: Any],
                let telemetry = root["telemetryLosses"] as? [String: Any],
                [event, telemetry].allSatisfy({
                    Set($0.keys) == ["exact", "lowerBound", "breakdown"]
                        || Set($0.keys) == ["lowerBound", "breakdown"]
                }),
                let metadata = try? JSONDecoder().decode(
                    SessionAcquisitionMetadata.self, from: data),
                metadata.isValid
            else {
                return (
                    nil, "Acquisition metadata is malformed or unsupported: \(url.path)", nil
                )
            }
            return (metadata, nil, sourceSHA256(data))
        } catch {
            return (nil, error.localizedDescription, nil)
        }
    }

    nonisolated static func sourceSHA256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Assembly

    private struct Assembled: Sendable {
        var samplePoints: [ChartPoint] = []
        var chartPoints: [ChartPoint] = []
        var processChartPoints: [ChartPoint] = []
        var gpuChartPoints: [ChartPoint] = []
        var gpuPowerChartPoints: [ChartPoint] = []
        var packagePowerChartPoints: [ChartPoint] = []
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
                    version: envelope.v,
                    sequence: envelope.sequence,
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
                processCPUPercent: sample.process?.cpuPercent,
                gpuBusyPercent: sample.system.gpuBusyPercent,
                gpuPowerWatts: sample.system.gpuPowerMilliwatts.map { $0 / 1_000 },
                packagePowerWatts: sample.system.packagePowerMilliwatts.map { $0 / 1_000 })
        }
        assembled.samplePoints = allPoints
        assembled.chartPoints = metricPreservingDownsample(allPoints)
        assembled.processChartPoints = assembled.chartPoints.filter {
            $0.processRSSGB != nil || $0.processCPUPercent != nil
        }
        assembled.gpuChartPoints = assembled.chartPoints.filter {
            $0.gpuBusyPercent != nil
        }
        assembled.gpuPowerChartPoints = assembled.chartPoints.filter { $0.gpuPowerWatts != nil }
        assembled.packagePowerChartPoints = assembled.chartPoints.filter {
            $0.packagePowerWatts != nil
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
        assembled.spans = TimelineGeometry.requestSpans(milestones: assembled.milestones)
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

    /// Allocate the 2k point budget across every displayed metric and retain
    /// the union of significant indices. A CPU, swap, or power spike must not
    /// disappear merely because memory happened to be flat in that bucket.
    private nonisolated static func metricPreservingDownsample(
        _ points: [ChartPoint]
    ) -> [ChartPoint] {
        guard points.count > maxChartPoints else { return points }
        let series: [(ChartPoint) -> Double?] = [
            { $0.systemUsedGB }, { $0.swapUsedGB }, { $0.processRSSGB },
            { $0.processCPUPercent }, { $0.gpuBusyPercent }, { $0.gpuPowerWatts },
            { $0.packagePowerWatts },
        ]
        let budget = max(3, maxChartPoints / series.count)
        var indices: Set<Int> = [0, points.count - 1]
        for value in series {
            let available = points.enumerated().compactMap { index, point in
                value(point).map { (index: index, point: point, value: $0) }
            }
            for selected in Downsample.lttb(
                available, to: budget,
                x: { $0.point.seconds }, y: { $0.value })
            {
                indices.insert(selected.index)
            }
        }
        return indices.sorted().map { points[$0] }
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
        case .transportSummary(let p):
            return "\(p.attemptedEvents) attempted · \(p.producerDroppedEvents) producer drops"
        case .error(let p):
            return "\(p.code): \(p.message)"
        }
    }
}
