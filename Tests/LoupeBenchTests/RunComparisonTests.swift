import XCTest

@testable import LoupeBench
@testable import LoupeCore

final class RunComparisonTests: XCTestCase {
    private func report(
        quantization: String = "4bit",
        chip: String = "Apple M3",
        memory: UInt64 = 16_000_000_000,
        decodeP50: Double = 200,
        ttftP50: Double = 100
    ) -> BenchmarkReport {
        let spec = BenchmarkSpec(
            model: "test-model", runtime: "mlx", quantization: quantization,
            contexts: [128], promptCorpus: ["p"], outputTokens: 32, repeats: 1)
        let metrics = RequestMetrics(
            requestId: "q-1", promptTokens: 128, outputTokens: 32,
            ttftNs: UInt64(ttftP50 * 1e6), decodeDurationNs: UInt64(32.0 / decodeP50 * 1e9))
        return BenchmarkReport(
            formatVersion: BenchmarkAssembler.formatVersion, spec: spec,
            host: HostFingerprint(
                chip: chip, model: "Mac1,1", performanceCores: 4, efficiencyCores: 4,
                memoryBytes: memory, osVersion: "15", osBuild: "24A"),
            createdAtNs: 1,
            provenance: BenchmarkProvenance(
                toolVersion: "1", adapterVersion: "1", runtimeVersion: "1",
                modelRevision: "rev",
                // SHA-256("synthetic model artifact fixture")
                modelArtifactSHA256:
                    "963f9166bacc92840908c6e0d15752306f9e30720216f8fa5ea0c829b0cd123d",
                // SHA-256("synthetic dependency lock fixture")
                dependencyLockSHA256:
                    "eb380ca914d512ec6d13c4d7543b1e6334334333a0f733819c34472b576baae2"),
            contexts: [
                BenchmarkReport.ContextResult(
                    contextTokens: 128,
                    runs: [BenchmarkReport.RunResult(runIndex: 0, requests: [metrics])],
                    ttftMs: DistributionSummary(values: [ttftP50]),
                    decodeTokensPerSecond: DistributionSummary(values: [decodeP50]))
            ])
    }

    func testMatchingSpecsProduceDeltas() {
        let comparison = RunComparison.compare(
            baseline: report(decodeP50: 200, ttftP50: 100),
            candidate: report(decodeP50: 220, ttftP50: 90))

        XCTAssertTrue(comparison.isComparable)
        XCTAssertTrue(comparison.mismatches.isEmpty)
        let deltas = comparison.deltas ?? []
        XCTAssertEqual(deltas.count, 2)
        let decode = deltas.first { $0.metric == "decode tok/s" }
        XCTAssertEqual(decode?.deltaPercent ?? 0, 10, accuracy: 0.001)
        let ttft = deltas.first { $0.metric == "TTFT ms" }
        XCTAssertEqual(ttft?.deltaPercent ?? 0, -10, accuracy: 0.001)
    }

    /// The acceptance test: mismatched specs list every differing dimension
    /// and the headline delta is refused — nil, not empty.
    func testMismatchedSpecsSuppressDeltasAndListEveryDifference() {
        let comparison = RunComparison.compare(
            baseline: report(quantization: "4bit", chip: "Apple M3"),
            candidate: report(quantization: "8bit", chip: "Apple M4 Pro"))

        XCTAssertFalse(comparison.isComparable)
        XCTAssertNil(comparison.deltas, "deltas must be absent, not merely empty")
        XCTAssertEqual(
            comparison.mismatches.map(\.name).sorted(), ["host.chip", "quantization"])
        let quant = comparison.mismatches.first { $0.name == "quantization" }
        XCTAssertEqual(quant?.baseline, "4bit")
        XCTAssertEqual(quant?.candidate, "8bit")
    }

    func testHardwareDifferencesAloneBlockComparison() {
        let comparison = RunComparison.compare(
            baseline: report(memory: 16_000_000_000),
            candidate: report(memory: 32_000_000_000))
        XCTAssertFalse(comparison.isComparable)
        XCTAssertEqual(comparison.mismatches.map(\.name), ["host.memory"])
        XCTAssertNil(comparison.deltas)
    }

    func testIdenticalReportsShowZeroDeltas() {
        let same = report()
        let comparison = RunComparison.compare(baseline: same, candidate: same)
        XCTAssertTrue(comparison.isComparable)
        for delta in comparison.deltas ?? [] {
            XCTAssertEqual(delta.deltaPercent, 0, accuracy: 0.000001)
        }
    }

    func testMissingProvenanceBlocksEvenIdenticalLegacyReports() {
        let current = report()
        let legacy = BenchmarkReport(
            formatVersion: 1, spec: current.spec, host: current.host,
            createdAtNs: current.createdAtNs, contexts: current.contexts)
        let comparison = RunComparison.compare(baseline: legacy, candidate: legacy)
        XCTAssertFalse(comparison.isComparable)
        XCTAssertNil(comparison.deltas)
        XCTAssertTrue(comparison.mismatches.contains { $0.name == "report.validity" })
    }

    func testOSBuildAndProvenanceDifferencesBlockComparison() {
        let baseline = report()
        let altered = BenchmarkReport(
            formatVersion: baseline.formatVersion,
            spec: baseline.spec,
            host: HostFingerprint(
                chip: baseline.host.chip, model: baseline.host.model,
                performanceCores: baseline.host.performanceCores,
                efficiencyCores: baseline.host.efficiencyCores,
                memoryBytes: baseline.host.memoryBytes,
                osVersion: baseline.host.osVersion, osBuild: "different"),
            createdAtNs: baseline.createdAtNs,
            provenance: BenchmarkProvenance(
                toolVersion: "1", adapterVersion: "1", runtimeVersion: "2",
                modelRevision: "rev",
                modelArtifactSHA256:
                    "963f9166bacc92840908c6e0d15752306f9e30720216f8fa5ea0c829b0cd123d",
                dependencyLockSHA256:
                    "eb380ca914d512ec6d13c4d7543b1e6334334333a0f733819c34472b576baae2"),
            contexts: baseline.contexts)
        let comparison = RunComparison.compare(baseline: baseline, candidate: altered)
        XCTAssertEqual(
            Set(comparison.mismatches.map(\.name)),
            Set(["host.osBuild", "provenance.runtimeVersion"]))
        XCTAssertNil(comparison.deltas)
    }

    func testTamperedSummaryBlocksComparison() {
        let original = report()
        let context = original.contexts[0]
        let tampered = BenchmarkReport(
            formatVersion: original.formatVersion, spec: original.spec, host: original.host,
            createdAtNs: original.createdAtNs, provenance: original.provenance,
            contexts: [
                BenchmarkReport.ContextResult(
                    contextTokens: context.contextTokens, runs: context.runs,
                    ttftMs: DistributionSummary(values: [9_999]),
                    decodeTokensPerSecond: context.decodeTokensPerSecond)
            ])

        let comparison = RunComparison.compare(baseline: original, candidate: tampered)
        XCTAssertFalse(comparison.isComparable)
        XCTAssertTrue(comparison.mismatches.contains { $0.name == "report.validity" })
        XCTAssertNil(comparison.deltas)
    }

    func testRequestThatDoesNotMatchSpecBlocksComparison() {
        let original = report()
        let context = original.contexts[0]
        let request = context.runs[0].requests[0]
        let tamperedRequest = RequestMetrics(
            requestId: request.requestId, promptTokens: 127,
            outputTokens: request.outputTokens, ttftNs: request.ttftNs,
            decodeDurationNs: request.decodeDurationNs)
        let tampered = BenchmarkReport(
            formatVersion: original.formatVersion, spec: original.spec, host: original.host,
            createdAtNs: original.createdAtNs, provenance: original.provenance,
            contexts: [
                BenchmarkReport.ContextResult(
                    contextTokens: context.contextTokens,
                    runs: [BenchmarkReport.RunResult(runIndex: 0, requests: [tamperedRequest])],
                    ttftMs: context.ttftMs,
                    decodeTokensPerSecond: context.decodeTokensPerSecond)
            ])

        XCTAssertEqual(tampered.validationFailures, ["requestMetrics"])
        let comparison = RunComparison.compare(baseline: original, candidate: tampered)
        XCTAssertFalse(comparison.isComparable)
        XCTAssertNil(comparison.deltas)
    }
}
