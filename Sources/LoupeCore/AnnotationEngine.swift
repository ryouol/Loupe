import Foundation

/// A rule-based finding pinned to a moment on the unified timeline, carrying
/// the exact observations that triggered it — an annotation without evidence
/// is an opinion, and profilers don't ship opinions.
public struct Annotation: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable, CaseIterable {
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

    public static func annotate(
        samples: [SystemSample], events: [EventEnvelope], config: Config = Config()
    ) -> [Annotation] {
        let ticks = events.filter { $0.kind == .decodeTick }.map(\.ts).sorted()
        var annotations: [Annotation] = []
        annotations += thermalThrottling(samples: samples, tickTimestamps: ticks, config: config)
        annotations += memoryPressure(samples: samples, tickTimestamps: ticks, config: config)
        annotations += prefillQueueing(events: events, config: config)
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
                in: tickTimestamps, from: at &- config.thermalWindowNs, to: at)
            let after = tokenRate(
                in: tickTimestamps, from: at, to: at &+ config.thermalWindowNs)
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
                                tickTimestamps, at &- config.thermalWindowNs,
                                at &+ config.thermalWindowNs)),
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
                let earlierIndex = nearestSampleIndex(in: samples, to: at &- window)
            else { continue }
            let earlier = samples[earlierIndex].system
            guard sample.system.swapUsedBytes > earlier.swapUsedBytes + config.swapRiseBytes
            else { continue }
            let rateEarlier = tokenRate(
                in: tickTimestamps, from: earlier.ts &- window, to: earlier.ts)
            let rateNow = tokenRate(in: tickTimestamps, from: at &- window, to: at)
            guard let rateEarlier, let rateNow,
                rateNow < rateEarlier * (1 - config.rateDropFraction),
                at &- lastAnnotatedNs > window
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
                            ticksBetween(tickTimestamps, earlier.ts &- window, at)),
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
        events: [EventEnvelope], config: Config
    ) -> [Annotation] {
        let metrics = SessionMetrics.perRequest(events: events)
        guard metrics.count >= 2 else { return [] }
        let sortedTTFTs = metrics.map(\.ttftNs).sorted()
        let median = Double(sortedTTFTs[sortedTTFTs.count / 2])
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
                    eventTimestamps: [at, at + metric.ttftNs],
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
                let requestId = envelope.requestId,
                !annotatedRequests.contains(requestId),
                let sampleIndex = nearestSampleIndex(in: samples, to: envelope.ts),
                let process = samples[sampleIndex].process,
                process.rssBytes > 0,
                Double(tick.kvCacheBytes) > Double(process.rssBytes) * config.kvFraction
            else { continue }
            annotatedRequests.insert(requestId)
            annotations.append(
                Annotation(
                    kind: .kvDominatedFootprint,
                    atNs: envelope.ts,
                    message:
                        "KV cache reached \(Int(100 * Double(tick.kvCacheBytes) / Double(process.rssBytes)))% "
                        + "of process memory during \(requestId).",
                    evidence: Annotation.Evidence(
                        sampleTimestamps: [samples[sampleIndex].system.ts],
                        eventTimestamps: [envelope.ts],
                        values: [
                            "kvCacheBytes": Double(tick.kvCacheBytes),
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
            // Only samples that actually carry GPU data count: a session
            // without the daemon must not read as "0% busy".
            let busyReadings = samples.filter {
                $0.system.ts >= window.start && $0.system.ts <= window.end
            }.compactMap { sample in
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
        .sorted { $0.atNs < $1.atNs }
    }

    // MARK: - Shared helpers

    /// Tokens per second in (from, to], nil when the window is empty of time.
    private static func tokenRate(
        in sortedTicks: [UInt64], from: UInt64, to: UInt64
    ) -> Double? {
        guard to > from else { return nil }
        let count = ticksBetween(sortedTicks, from, to).count
        let seconds = Double(to - from) / 1e9
        return Double(count) / seconds
    }

    private static func ticksBetween(
        _ sortedTicks: [UInt64], _ from: UInt64, _ to: UInt64
    ) -> [UInt64] {
        let lower = lowerBound(sortedTicks, from)
        let upper = lowerBound(sortedTicks, to)
        guard lower < upper else { return [] }
        return Array(sortedTicks[lower..<upper])
    }

    private static func lowerBound(_ sorted: [UInt64], _ value: UInt64) -> Int {
        var low = 0
        var high = sorted.count
        while low < high {
            let mid = (low + high) / 2
            if sorted[mid] < value { low = mid + 1 } else { high = mid }
        }
        return low
    }

    private static func nearestSampleIndex(in samples: [SystemSample], to ts: UInt64) -> Int? {
        guard !samples.isEmpty else { return nil }
        var low = 0
        var high = samples.count - 1
        while low < high {
            let mid = (low + high) / 2
            if samples[mid].system.ts < ts { low = mid + 1 } else { high = mid }
        }
        if low > 0,
            ts &- samples[low - 1].system.ts < samples[low].system.ts &- ts
        {
            return low - 1
        }
        return low
    }

    private static func cap(_ timestamps: [UInt64]) -> [UInt64] {
        Array(timestamps.prefix(evidenceCap))
    }

    private static func dropPercent(before: Double, after: Double) -> Int {
        Int(((before - after) / before * 100).rounded())
    }

    private static func formatBytes(_ bytes: UInt64) -> String {
        bytes >= 1_048_576
            ? String(format: "%.1f MB", Double(bytes) / 1_048_576)
            : "\(bytes / 1_024) KB"
    }
}
