import Foundation
import XCTest

@testable import LoupeBench
@testable import LoupeCore

final class StatisticsTests: XCTestCase {
    func testNearestRankPercentiles() {
        let summary = DistributionSummary(values: (1...100).map(Double.init))
        XCTAssertEqual(summary.p50, 50)
        XCTAssertEqual(summary.p95, 95)
        XCTAssertEqual(summary.min, 1)
        XCTAssertEqual(summary.max, 100)
        XCTAssertEqual(summary.count, 100)
        XCTAssertEqual(summary.mean, 50.5, accuracy: 0.0001)
    }

    func testSmallSamplesAndSpread() {
        let summary = DistributionSummary(values: [2, 4, 4, 4, 5, 5, 7, 9])
        XCTAssertEqual(summary.mean, 5, accuracy: 0.0001)
        XCTAssertEqual(summary.stddev, 2.138, accuracy: 0.001)

        let single = DistributionSummary(values: [42])
        XCTAssertEqual(single.p50, 42)
        XCTAssertEqual(single.p95, 42)
        XCTAssertEqual(single.stddev, 0)

        let empty = DistributionSummary(values: [])
        XCTAssertEqual(empty.count, 0)
        XCTAssertEqual(empty.p50, 0)
    }
}

final class SessionMetricsTests: XCTestCase {
    private func envelope(
        _ payload: EventPayload, ts: UInt64, requestId: String?
    ) -> EventEnvelope {
        EventEnvelope(ts: ts, runId: "r-m", requestId: requestId, payload: payload)
    }

    func testDerivesTTFTAndDecodeRate() {
        let events: [EventEnvelope] = [
            envelope(.requestStart(.init(promptTokens: nil)), ts: 1_000_000_000, requestId: "q-1"),
            envelope(.prefillEnd(.init(promptTokens: 128)), ts: 1_250_000_000, requestId: "q-1"),
            envelope(
                .decodeTick(.init(outputTokens: 1, kvCacheBytes: 1, activeMemoryBytes: 1)),
                ts: 1_260_000_000, requestId: "q-1"),
            envelope(
                .requestEnd(.init(outputTokens: 50, finishReason: "stop")),
                ts: 2_250_000_000, requestId: "q-1"),
        ]
        let metrics = SessionMetrics.perRequest(events: events)
        XCTAssertEqual(metrics.count, 1)
        XCTAssertEqual(metrics[0].ttftNs, 250_000_000)
        XCTAssertEqual(metrics[0].ttftMs, 250, accuracy: 0.0001)
        XCTAssertEqual(metrics[0].promptTokens, 128)
        // 50 tokens over exactly 1 second of decode.
        XCTAssertEqual(metrics[0].decodeTokensPerSecond, 50, accuracy: 0.0001)
    }

    func testIncompleteRequestsAreSkippedNotInvented() {
        let events: [EventEnvelope] = [
            envelope(.requestStart(.init(promptTokens: nil)), ts: 10, requestId: "q-lost"),
            // No prefill_end, no request_end (crashed mid-prefill).
            envelope(.requestStart(.init(promptTokens: nil)), ts: 20, requestId: "q-ok"),
            envelope(.prefillEnd(.init(promptTokens: 8)), ts: 30, requestId: "q-ok"),
            envelope(
                .requestEnd(.init(outputTokens: 4, finishReason: "stop")), ts: 40,
                requestId: "q-ok"),
        ]
        let metrics = SessionMetrics.perRequest(events: events)
        XCTAssertEqual(metrics.map(\.requestId), ["q-ok"])
    }

    func testRequestsKeepStreamOrder() {
        var events: [EventEnvelope] = []
        for (index, id) in ["q-3", "q-1", "q-2"].enumerated() {
            let base = UInt64(index * 100 + 10)
            events.append(
                envelope(.requestStart(.init(promptTokens: nil)), ts: base, requestId: id))
            events.append(
                envelope(.prefillEnd(.init(promptTokens: 1)), ts: base + 10, requestId: id))
            events.append(
                envelope(
                    .requestEnd(.init(outputTokens: 1, finishReason: "stop")), ts: base + 20,
                    requestId: id))
        }
        XCTAssertEqual(
            SessionMetrics.perRequest(events: events).map(\.requestId), ["q-3", "q-1", "q-2"])
    }
}

final class CooldownGateTests: XCTestCase {
    func testAlreadyNominalPassesImmediately() async {
        let stream = AsyncStream<ThermalState> { continuation in
            continuation.yield(.nominal)
        }
        let outcome = await CooldownGate.waitForNominal(states: stream, timeout: .seconds(5))
        XCTAssertEqual(outcome, .nominal)
    }

    func testReachingNominalLaterPasses() async {
        let stream = AsyncStream<ThermalState> { continuation in
            continuation.yield(.serious)
            Task {
                try? await Task.sleep(for: .milliseconds(30))
                continuation.yield(.fair)
                continuation.yield(.nominal)
            }
        }
        let outcome = await CooldownGate.waitForNominal(states: stream, timeout: .seconds(5))
        XCTAssertEqual(outcome, .nominal)
    }

    func testNeverNominalTimesOutCleanlyInsteadOfHanging() async {
        let stream = AsyncStream<ThermalState> { continuation in
            continuation.yield(.critical)
            // Stream stays open and never reaches nominal.
        }
        let clock = ContinuousClock()
        let start = clock.now
        let outcome = await CooldownGate.waitForNominal(
            states: stream, timeout: .milliseconds(80))
        let elapsed = clock.now - start
        XCTAssertEqual(outcome, .timedOut)
        XCTAssertLessThan(elapsed, .seconds(2), "timeout must not hang")
    }
}

final class BenchmarkSpecTests: XCTestCase {
    func testYAMLRoundTrip() throws {
        let yaml = """
            model: mlx-community/Qwen2.5-0.5B-Instruct-4bit
            runtime: mlx
            quantization: 4bit
            contexts: [128, 512]
            batch: 1
            promptCorpus:
              - "Explain prefill vs decode."
            outputTokens: 32
            repeats: 3
            warmup: 1
            seed: 42
            cooldownTimeoutSeconds: 60
            """
        let spec = try BenchmarkSpec.fromYAML(yaml)
        XCTAssertEqual(spec.contexts, [128, 512])
        XCTAssertEqual(spec.repeats, 3)
        XCTAssertEqual(spec.seed, 42)
        XCTAssertEqual(spec.comparableDimensions.map(\.name).count, 7)
    }

    func testMalformedYAMLThrows() {
        XCTAssertThrowsError(try BenchmarkSpec.fromYAML("model: [unclosed"))
        XCTAssertThrowsError(try BenchmarkSpec.fromYAML("runtime: mlx"))
    }
}

final class BenchmarkGoldenFileTests: XCTestCase {
    private static let goldenURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("golden-report.json")

    /// Deterministic synthetic runs: 2 contexts x 2 measured runs each.
    private func syntheticReport() -> BenchmarkReport {
        func run(context: Int, index: Int) -> [EventEnvelope] {
            let base = UInt64(context * 1_000_000 + index * 1_000)
            let requestId = "q-1"
            let runId = "r-c\(context)-\(index)"
            func make(_ payload: EventPayload, _ offset: UInt64) -> EventEnvelope {
                EventEnvelope(
                    ts: base + offset, runId: runId, requestId: requestId, payload: payload)
            }
            return [
                make(.requestStart(.init(promptTokens: nil)), 0),
                make(.prefillEnd(.init(promptTokens: UInt32(context))), UInt64(context) * 1_000),
                make(
                    .requestEnd(.init(outputTokens: 32, finishReason: "stop")),
                    UInt64(context) * 1_000 + UInt64(500_000_000 + index * 10_000_000)),
            ]
        }
        let spec = BenchmarkSpec(
            model: "test-model", runtime: "mlx", quantization: "4bit",
            contexts: [128, 512], promptCorpus: ["p"], outputTokens: 32,
            repeats: 2, warmup: 1, seed: 7, cooldownTimeoutSeconds: 60)
        return BenchmarkAssembler.report(
            spec: spec,
            host: HostFingerprint(
                chip: "Test Chip", model: "Test1,1", performanceCores: 4, efficiencyCores: 4,
                memoryBytes: 16_000_000_000, osVersion: "15.0", osBuild: "24A000"),
            createdAtNs: 123_456_789,
            measuredRunsByContext: [
                128: [run(context: 128, index: 0), run(context: 128, index: 1)],
                512: [run(context: 512, index: 0), run(context: 512, index: 1)],
            ])
    }

    /// The report structure is a contract consumed by the results view and
    /// the comparison engine; this golden file pins it. If it fails because
    /// the format deliberately changed, bump formatVersion and regenerate —
    /// never regenerate to silence an accidental change.
    func testFixedSpecProducesStableReportStructure() throws {
        let encoded = try BenchmarkAssembler.encode(syntheticReport())
        if ProcessInfo.processInfo.environment["LOUPE_RECORD_GOLDEN"] == "1" {
            try encoded.write(to: Self.goldenURL)
            XCTFail("golden file recorded — rerun without LOUPE_RECORD_GOLDEN to verify")
            return
        }
        let golden = try Data(contentsOf: Self.goldenURL)
        XCTAssertEqual(
            String(decoding: encoded, as: UTF8.self),
            String(decoding: golden, as: UTF8.self))
    }

    func testReportRoundTripsThroughItsCodec() throws {
        let report = syntheticReport()
        let decoded = try BenchmarkAssembler.decode(BenchmarkAssembler.encode(report))
        XCTAssertEqual(decoded, report)
        XCTAssertEqual(decoded.contexts.map(\.contextTokens), [128, 512])
        XCTAssertEqual(decoded.contexts[0].ttftMs.count, 2)
    }
}
