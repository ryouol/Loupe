/// Diff of two benchmark reports. Specs compare first, and a single
/// mismatched dimension structurally suppresses every delta: a headline
/// number comparing different configurations is misinformation with a
/// percent sign, and this type makes it unrepresentable.
public struct RunComparison: Sendable, Equatable {
    public struct DimensionMismatch: Sendable, Equatable, Identifiable {
        public var id: String { name }
        public let name: String
        public let baseline: String
        public let candidate: String
    }

    public struct MetricDelta: Sendable, Equatable, Identifiable {
        public var id: String { "\(metric)-\(contextTokens)" }
        public let contextTokens: Int
        /// Human-readable metric name shared with the export columns.
        public let metric: String
        public let baselineP50: Double
        public let candidateP50: Double
        /// Positive = candidate higher. Sign interpretation (better/worse)
        /// belongs to the metric, not this engine.
        public var deltaPercent: Double {
            guard baselineP50 != 0 else { return 0 }
            return (candidateP50 - baselineP50) / baselineP50 * 100
        }
    }

    public let mismatches: [DimensionMismatch]
    /// nil whenever specs mismatch — not empty, absent.
    public let deltas: [MetricDelta]?

    public var isComparable: Bool { mismatches.isEmpty }

    public static func compare(
        baseline: BenchmarkReport, candidate: BenchmarkReport
    ) -> RunComparison {
        var mismatches: [DimensionMismatch] = []

        if !baseline.validationFailures.isEmpty || !candidate.validationFailures.isEmpty {
            mismatches.append(
                DimensionMismatch(
                    name: "report.validity",
                    baseline: baseline.validationFailures.isEmpty
                        ? "valid" : baseline.validationFailures.joined(separator: ","),
                    candidate: candidate.validationFailures.isEmpty
                        ? "valid" : candidate.validationFailures.joined(separator: ",")))
        }

        if baseline.formatVersion != candidate.formatVersion {
            mismatches.append(
                DimensionMismatch(
                    name: "formatVersion",
                    baseline: String(baseline.formatVersion),
                    candidate: String(candidate.formatVersion)))
        }

        let baselineDimensions = baseline.spec.comparableDimensions
        let candidateDimensions = candidate.spec.comparableDimensions
        for (lhs, rhs) in zip(baselineDimensions, candidateDimensions) where lhs.value != rhs.value
        {
            mismatches.append(
                DimensionMismatch(name: lhs.name, baseline: lhs.value, candidate: rhs.value))
        }
        if let baselineProvenance = baseline.provenance,
            let candidateProvenance = candidate.provenance
        {
            for (lhs, rhs) in zip(
                baselineProvenance.comparableDimensions,
                candidateProvenance.comparableDimensions)
            where lhs.value != rhs.value {
                mismatches.append(
                    DimensionMismatch(name: lhs.name, baseline: lhs.value, candidate: rhs.value))
            }
        }
        // Hardware is a spec dimension in every sense that matters: numbers
        // from different chips or memory sizes are not comparable.
        if baseline.host.chip != candidate.host.chip {
            mismatches.append(
                DimensionMismatch(
                    name: "host.chip", baseline: baseline.host.chip,
                    candidate: candidate.host.chip))
        }
        if baseline.host.memoryBytes != candidate.host.memoryBytes {
            mismatches.append(
                DimensionMismatch(
                    name: "host.memory",
                    baseline: "\(baseline.host.memoryBytes)",
                    candidate: "\(candidate.host.memoryBytes)"))
        }
        let hostDimensions: [(String, String, String)] = [
            ("host.model", baseline.host.model, candidate.host.model),
            (
                "host.performanceCores", String(baseline.host.performanceCores),
                String(candidate.host.performanceCores)
            ),
            (
                "host.efficiencyCores", String(baseline.host.efficiencyCores),
                String(candidate.host.efficiencyCores)
            ),
            ("host.osVersion", baseline.host.osVersion, candidate.host.osVersion),
            ("host.osBuild", baseline.host.osBuild, candidate.host.osBuild),
        ]
        for (name, lhs, rhs) in hostDimensions where lhs != rhs {
            mismatches.append(DimensionMismatch(name: name, baseline: lhs, candidate: rhs))
        }

        guard mismatches.isEmpty else {
            return RunComparison(mismatches: mismatches, deltas: nil)
        }

        var deltas: [MetricDelta] = []
        let candidateByContext = Dictionary(
            uniqueKeysWithValues: candidate.contexts.map { ($0.contextTokens, $0) })
        for baselineContext in baseline.contexts {
            guard let candidateContext = candidateByContext[baselineContext.contextTokens]
            else { continue }
            deltas.append(
                MetricDelta(
                    contextTokens: baselineContext.contextTokens,
                    metric: "decode tok/s",
                    baselineP50: baselineContext.decodeTokensPerSecond.p50,
                    candidateP50: candidateContext.decodeTokensPerSecond.p50))
            deltas.append(
                MetricDelta(
                    contextTokens: baselineContext.contextTokens,
                    metric: "TTFT ms",
                    baselineP50: baselineContext.ttftMs.p50,
                    candidateP50: candidateContext.ttftMs.p50))
        }
        return RunComparison(mismatches: [], deltas: deltas)
    }
}
