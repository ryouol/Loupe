import Foundation

/// A rule-based finding pinned to a moment on the unified timeline, carrying
/// the exact observations that triggered it — an annotation without evidence
/// is an opinion, and profilers don't ship opinions.
public struct Annotation: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable {
        case thermalThrottling = "thermal_throttling"
        case memoryPressure = "memory_pressure"
        case prefillQueueing = "prefill_queueing"
        case kvDominatedFootprint = "kv_dominated_footprint"
        case gpuUnderutilized = "gpu_underutilized"
    }

    public struct Evidence: Sendable, Equatable {
        /// Timestamps of the telemetry samples and events this finding rests
        /// on (capped, in order), plus the named quantities compared.
        public let sampleTimestamps: [UInt64]
        public let eventTimestamps: [UInt64]
        public let values: [String: Double]
    }

    public var id: String { "\(kind.rawValue)-\(atNs)" }
    public let kind: Kind
    /// The linkable moment on the unified clock.
    public let atNs: UInt64
    public let message: String
    public let evidence: Evidence
}

/// The five shipped rules. Rule-based only — every threshold is visible,
/// documented, and testable; no scoring, no inference.
public enum AnnotationEngine {
    public struct Config: Sendable {
        /// Rule 1/2: a decode-rate drop counts past this fraction.
        public var rateDropFraction = 0.15
        /// Rule 1: window on each side of a thermal increase.
        public var thermalWindowNs: UInt64 = 5_000_000_000
        /// Rule 2: swap growth that counts as "rising".
        public var swapRiseBytes: UInt64 = 1_048_576
        /// Rule 3: TTFT beyond this multiple of the run median.
        public var ttftMedianMultiplier = 3.0
        /// Rule 4: KV bytes beyond this fraction of process RSS.
        public var kvFraction = 0.4
        /// Rule 5: mean GPU busy below this during decode.
        public var gpuBusyThreshold = 50.0
        public init() {}
    }

    private static let evidenceCap = 32

    /// Pass precomputed metrics when the caller already has them (the
    /// session assembler does); nil recomputes from the events.
    public static func annotate(
        samples: [SystemSample], events: [EventEnvelope],
        metrics: [RequestMetrics]? = nil, config: Config = Config()
    ) -> [Annotation] {
        let ticks = events.filter { $0.kind == .decodeTick }.map(\.ts).sorted()
        let requestMetrics = metrics ?? SessionMetrics.perRequest(events: events)
        var annotations: [Annotation] = []
        annotations += thermalThrottling(samples: samples, tickTimestamps: ticks, config: config)
        annotations += memoryPressure(samples: samples, tickTimestamps: ticks, config: config)
        annotations += prefillQueueing(events: events, metrics: requestMetrics, config: config)
        annotations += kvDominated(samples: samples, events: events, config: config)
        annotations += gpuUnderutilized(samples: samples, events: events, config: config)
        return annotations.sorted { $0.atNs < $1.atNs }
    }

    // MARK: Rule 1 — decode rate drops >15% within 5s of a thermal increase

    private static func thermalThrottling(
        samples: [SystemSample], tickTimestamps: [UInt64], config: Config
    ) -> [Annotation] {
        var annotations: [Annotation] = []
        for index in 1..<max(1, samples.count) {
            let previous = samples[index - 1].system
            let current = samples[index].system
            guard current.thermalState > previous.thermalState else { continue }
            let at = current.ts
            let before = tokenRate(
                in: tickTimestamps, from: subtracting(config.thermalWindowNs, from: at), to: at)
            let after = tokenRate(
                in: tickTimestamps, from: at, to: adding(config.thermalWindowNs, to: at))
            guard let before, let after, after < before * (1 - config.rateDropFraction)
            else { continue }
            annotations.append(
                Annotation(
                    kind: .thermalThrottling,
                    atNs: at,
                    message:
                        "Decode rate fell \(dropPercent(before: before, after: after))% within "
                        + "5s of thermal state rising to \(current.thermalState.rawValue).",
                    evidence: Annotation.Evidence(
                        sampleTimestamps: [previous.ts, current.ts],
                        eventTimestamps: cap(
                            ticksBetween(
                                tickTimestamps, subtracting(config.thermalWindowNs, from: at),
                                adding(config.thermalWindowNs, to: at))),
                        values: [
                            "rateBeforePerSecond": before,
                            "rateAfterPerSecond": after,
                        ])))
        }
        return annotations
    }

    // MARK: Rule 2 — decode rate drop while swap grows

    private static func memoryPressure(
        samples: [SystemSample], tickTimestamps: [UInt64], config: Config
    ) -> [Annotation] {
        var annotations: [Annotation] = []
        var lastAnnotatedNs: UInt64 = 0
        let window: UInt64 = 5_000_000_000
        for sample in samples {
            let at = sample.system.ts
            guard at > window,
                let earlierIndex = nearestSampleIndex(
                    in: samples, to: subtracting(window, from: at))
            else { continue }
            let earlier = samples[earlierIndex].system
            guard sample.system.swapUsedBytes > earlier.swapUsedBytes,
                sample.system.swapUsedBytes - earlier.swapUsedBytes > config.swapRiseBytes
            else { continue }
            let rateEarlier = tokenRate(
                in: tickTimestamps, from: subtracting(window, from: earlier.ts), to: earlier.ts)
            let rateNow = tokenRate(
                in: tickTimestamps, from: subtracting(window, from: at), to: at)
            guard let rateEarlier, let rateNow,
                rateNow < rateEarlier * (1 - config.rateDropFraction),
                at > adding(window, to: lastAnnotatedNs)
            else { continue }
            lastAnnotatedNs = at
            annotations.append(
                Annotation(
                    kind: .memoryPressure,
                    atNs: at,
                    message:
                        "Decode rate fell \(dropPercent(before: rateEarlier, after: rateNow))% "
                        + "while swap grew \(formatBytes(sample.system.swapUsedBytes - earlier.swapUsedBytes)).",
                    evidence: Annotation.Evidence(
                        sampleTimestamps: [earlier.ts, at],
                        eventTimestamps: cap(
                            ticksBetween(
                                tickTimestamps, subtracting(window, from: earlier.ts), at)),
                        values: [
                            "rateBeforePerSecond": rateEarlier,
                            "rateAfterPerSecond": rateNow,
                            "swapRiseBytes": Double(
                                sample.system.swapUsedBytes - earlier.swapUsedBytes),
                        ])))
        }
        return annotations
    }

    // MARK: Rule 3 — TTFT > 3x the run median

    private static func prefillQueueing(
        events: [EventEnvelope], metrics: [RequestMetrics], config: Config
    ) -> [Annotation] {
        guard metrics.count >= 2 else { return [] }
        let sortedTTFTs = metrics.map(\.ttftNs).sorted()
        // Nearest-rank p50 (lower middle on even counts) — the same
        // convention DistributionSummary uses, so an annotation's "run
        // median" agrees with the number in the results table.
        let median = Double(sortedTTFTs[(sortedTTFTs.count + 1) / 2 - 1])
        guard median > 0 else { return [] }

        var startTsByRequest: [String: UInt64] = [:]
        for envelope in events where envelope.kind == .requestStart {
            if let requestId = envelope.requestId {
                startTsByRequest[requestId] = envelope.ts
            }
        }

        return metrics.compactMap { metric in
            guard Double(metric.ttftNs) > median * config.ttftMedianMultiplier,
                let at = startTsByRequest[metric.requestId]
            else { return nil }
            return Annotation(
                kind: .prefillQueueing,
                atNs: at,
                message:
                    "Request \(metric.requestId) waited \(String(format: "%.0f", metric.ttftMs))ms "
                    + "for its first token — \(String(format: "%.1f", Double(metric.ttftNs) / median))x the run median.",
                evidence: Annotation.Evidence(
                    sampleTimestamps: [],
                    eventTimestamps: [at, adding(metric.ttftNs, to: at)],
                    values: [
                        "ttftNs": Double(metric.ttftNs),
                        "medianTtftNs": median,
                    ]))
        }
    }

    // MARK: Rule 4 — KV cache > 40% of process memory

    private static func kvDominated(
        samples: [SystemSample], events: [EventEnvelope], config: Config
    ) -> [Annotation] {
        var annotatedRequests: Set<String> = []
        var annotations: [Annotation] = []
        for envelope in events {
            guard case .decodeTick(let tick) = envelope.payload,
                let kvCacheBytes = tick.kvCacheBytes,
                tick.memoryProvenance == .runtimeMeasuredKV
                    || tick.memoryProvenance == .architectureModeledKV,
                let requestId = envelope.requestId,
                !annotatedRequests.contains(requestId),
                let sampleIndex = nearestSampleIndex(in: samples, to: envelope.ts),
                let process = samples[sampleIndex].process,
                process.rssBytes > 0,
                Double(kvCacheBytes) > Double(process.rssBytes) * config.kvFraction
            else { continue }
            annotatedRequests.insert(requestId)
            let percentage = 100 * Double(kvCacheBytes) / Double(process.rssBytes)
            let provenanceLabel =
                tick.memoryProvenance == .runtimeMeasuredKV ? "Runtime-measured" : "Modeled"
            annotations.append(
                Annotation(
                    kind: .kvDominatedFootprint,
                    atNs: envelope.ts,
                    message:
                        "\(provenanceLabel) KV cache reached \(String(format: "%.0f", percentage))% "
                        + "of process memory during \(requestId).",
                    evidence: Annotation.Evidence(
                        sampleTimestamps: [samples[sampleIndex].system.ts],
                        eventTimestamps: [envelope.ts],
                        values: [
                            "kvCacheBytes": Double(kvCacheBytes),
                            "processRSSBytes": Double(process.rssBytes),
                        ])))
        }
        return annotations
    }

    // MARK: Rule 5 — GPU busy < 50% during decode

    private static func gpuUnderutilized(
        samples: [SystemSample], events: [EventEnvelope], config: Config
    ) -> [Annotation] {
        var windows: [String: (start: UInt64, end: UInt64)] = [:]
        var prefillEnd: [String: UInt64] = [:]
        for envelope in events {
            guard let requestId = envelope.requestId else { continue }
            switch envelope.kind {
            case .prefillEnd: prefillEnd[requestId] = envelope.ts
            case .requestEnd:
                if let start = prefillEnd[requestId] {
                    windows[requestId] = (start, envelope.ts)
                }
            default: break
            }
        }

        return windows.compactMap { requestId, window in
            // Binary-search the window bounds — a linear scan over every
            // sample per request goes quadratic on hour-long sessions.
            let start = SortedSearch.lowerBound(
                samples, value: window.start, key: \.system.ts)
            let end =
                window.end == UInt64.max
                ? samples.count
                : SortedSearch.lowerBound(
                    samples, value: window.end + 1, key: \.system.ts)
            guard start < end else { return nil }
            // Only samples that actually carry GPU data count: a session
            // without the daemon must not read as "0% busy".
            let busyReadings = samples[start..<end].compactMap { sample in
                sample.system.gpuBusyPercent.map { (ts: sample.system.ts, busy: $0) }
            }
            guard busyReadings.count >= 3 else { return nil }
            let mean = busyReadings.map(\.busy).reduce(0, +) / Double(busyReadings.count)
            guard mean < config.gpuBusyThreshold else { return nil }
            return Annotation(
                kind: .gpuUnderutilized,
                atNs: window.start,
                message:
                    "GPU averaged \(String(format: "%.0f", mean))% busy while decoding "
                    + "\(requestId) — likely CPU-bound or memory-bandwidth-bound.",
                evidence: Annotation.Evidence(
                    sampleTimestamps: cap(busyReadings.map(\.ts)),
                    eventTimestamps: [window.start, window.end],
                    values: ["meanGpuBusyPercent": mean]))
        }
    }

    // MARK: - Shared helpers

    /// Tokens per second in (from, to], nil when the window is empty of
    /// time. Counting via bound subtraction — materializing the window just
    /// to count it allocates on every probe.
    private static func tokenRate(
        in sortedTicks: [UInt64], from: UInt64, to: UInt64
    ) -> Double? {
        guard to > from else { return nil }
        let count =
            SortedSearch.lowerBound(sortedTicks, value: to, key: { $0 })
            - SortedSearch.lowerBound(sortedTicks, value: from, key: { $0 })
        let seconds = Double(to - from) / 1e9
        return Double(count) / seconds
    }

    /// Materialized only for evidence, once a finding actually fires.
    private static func ticksBetween(
        _ sortedTicks: [UInt64], _ from: UInt64, _ to: UInt64
    ) -> [UInt64] {
        let lower = SortedSearch.lowerBound(sortedTicks, value: from, key: { $0 })
        let upper = SortedSearch.lowerBound(sortedTicks, value: to, key: { $0 })
        guard lower < upper else { return [] }
        return Array(sortedTicks[lower..<upper])
    }

    private static func nearestSampleIndex(in samples: [SystemSample], to ts: UInt64) -> Int? {
        SortedSearch.nearestIndex(
            samples, to: ts, key: \.system.ts,
            distance: { $0 >= $1 ? $0 - $1 : $1 - $0 })
    }

    private static func cap(_ timestamps: [UInt64]) -> [UInt64] {
        Array(timestamps.prefix(evidenceCap))
    }

    private static func subtracting(_ amount: UInt64, from value: UInt64) -> UInt64 {
        value >= amount ? value - amount : 0
    }

    private static func adding(_ amount: UInt64, to value: UInt64) -> UInt64 {
        value <= UInt64.max - amount ? value + amount : UInt64.max
    }

    private static func dropPercent(before: Double, after: Double) -> Int {
        guard before > 0 else { return 0 }
        let percentage = ((before - after) / before * 100).rounded()
        guard percentage.isFinite else { return 0 }
        return Int(max(0, min(100, percentage)))
    }

    /// Same formatter convention as every display site (Format.swift).
    private static func formatBytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .memory)
    }
}
