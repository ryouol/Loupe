import XCTest

@testable import LoupeCore

/// Per the acceptance: every rule has a synthetic fixture that triggers it
/// and one that must not.
final class AnnotationEngineTests: XCTestCase {
    private let second: UInt64 = 1_000_000_000

    // MARK: Builders

    private func sample(
        ts: UInt64, thermal: ThermalState = .nominal, swap: UInt64 = 0,
        rss: UInt64? = nil, gpuBusy: Double? = nil
    ) -> SystemSample {
        SystemSample(
            system: SystemWideSample(
                ts: ts, thermalState: thermal, memoryUsedBytes: 8_000_000_000,
                memoryFreeBytes: 4_000_000_000, swapUsedBytes: swap,
                gpuBusyPercent: gpuBusy),
            process: rss.map { ProcessSample(ts: ts, pid: 7, cpuPercent: 50, rssBytes: $0) })
    }

    private func tick(
        ts: UInt64, requestId: String = "q-1", tokens: UInt32 = 1, kv: UInt64 = 1
    ) -> EventEnvelope {
        EventEnvelope(
            ts: ts, runId: "r-a", requestId: requestId,
            payload: .decodeTick(
                DecodeTickPayload(
                    outputTokens: tokens, kvCacheBytes: kv, activeMemoryBytes: kv + 1,
                    memoryProvenance: .architectureModeledKV)))
    }

    private func request(
        _ id: String, startTs: UInt64, prefillTs: UInt64, endTs: UInt64,
        firstOutputTs: UInt64? = nil, tokens: UInt32 = 10
    ) -> [EventEnvelope] {
        [
            EventEnvelope(
                ts: startTs, runId: "r-a", requestId: id,
                payload: .requestStart(RequestStartPayload(promptTokens: nil))),
            EventEnvelope(
                ts: prefillTs, runId: "r-a", requestId: id,
                payload: .prefillEnd(PrefillEndPayload(promptTokens: 64))),
            tick(ts: firstOutputTs ?? prefillTs, requestId: id, tokens: 1),
            EventEnvelope(
                ts: endTs, runId: "r-a", requestId: id,
                payload: .requestEnd(
                    RequestEndPayload(outputTokens: tokens, finishReason: "stop"))),
        ]
    }

    /// Ticks at a steady rate over a window.
    private func steadyTicks(
        from: UInt64, to: UInt64, perSecond: Int, requestId: String = "q-1"
    ) -> [EventEnvelope] {
        let interval = second / UInt64(perSecond)
        var events: [EventEnvelope] = []
        var ts = from
        var count: UInt32 = 1
        while ts < to {
            events.append(tick(ts: ts, requestId: requestId, tokens: count))
            ts += interval
            count += 1
        }
        return events
    }

    private func annotations(
        samples: [SystemSample], events: [EventEnvelope]
    ) -> [Annotation] {
        AnnotationEngine.annotate(samples: samples, events: events)
    }

    // MARK: Rule 1 — thermal throttling

    func testThermalThrottlingTriggers() {
        // 20 tok/s before the state change, 10 tok/s after: a 50% drop.
        let changeAt = 10 * second
        let events =
            steadyTicks(from: changeAt - 5 * second, to: changeAt, perSecond: 20)
            + steadyTicks(from: changeAt, to: changeAt + 5 * second, perSecond: 10)
        let samples = [
            sample(ts: changeAt - second, thermal: .nominal),
            sample(ts: changeAt, thermal: .serious),
            sample(ts: changeAt + second, thermal: .serious),
        ]
        let found = annotations(samples: samples, events: events)
        let throttling = found.filter { $0.kind == .thermalThrottling }
        XCTAssertEqual(throttling.count, 1)
        XCTAssertEqual(throttling[0].atNs, changeAt)
        XCTAssertEqual(throttling[0].evidence.values["rateBeforePerSecond"] ?? 0, 20, accuracy: 1)
        XCTAssertEqual(throttling[0].evidence.values["rateAfterPerSecond"] ?? 0, 10, accuracy: 1)
        XCTAssertFalse(throttling[0].evidence.eventTimestamps.isEmpty)
    }

    func testThermalChangeWithoutRateDropDoesNotTrigger() {
        // Same thermal increase, decode rate steady: no annotation.
        let changeAt = 10 * second
        let events = steadyTicks(
            from: changeAt - 5 * second, to: changeAt + 5 * second, perSecond: 20)
        let samples = [
            sample(ts: changeAt - second, thermal: .nominal),
            sample(ts: changeAt, thermal: .serious),
        ]
        XCTAssertTrue(
            annotations(samples: samples, events: events)
                .filter { $0.kind == .thermalThrottling }.isEmpty)
    }

    // MARK: Rule 2 — memory pressure

    func testMemoryPressureTriggers() {
        // Swap grows 50MB across the window while decode halves.
        let pivot = 20 * second
        let events =
            steadyTicks(from: pivot - 10 * second, to: pivot - 4 * second, perSecond: 20)
            + steadyTicks(from: pivot - 4 * second, to: pivot + 5 * second, perSecond: 8)
        var samples: [SystemSample] = []
        for offset in stride(from: -10, through: 5, by: 1) {
            let ts = UInt64(Int64(pivot) + Int64(offset) * Int64(second))
            let swap: UInt64 = offset < -4 ? 10_000_000 : UInt64(60_000_000 + offset * 1_000_000)
            samples.append(sample(ts: ts, swap: swap))
        }
        let found = annotations(samples: samples, events: events)
            .filter { $0.kind == .memoryPressure }
        XCTAssertFalse(found.isEmpty, "swap rise + rate drop must annotate")
        XCTAssertGreaterThan(found[0].evidence.values["swapRiseBytes"] ?? 0, 1_048_576)
    }

    func testSwapRiseWithSteadyDecodeDoesNotTrigger() {
        let pivot = 20 * second
        let events = steadyTicks(
            from: pivot - 10 * second, to: pivot + 5 * second, perSecond: 20)
        var samples: [SystemSample] = []
        for offset in stride(from: -10, through: 5, by: 1) {
            let ts = UInt64(Int64(pivot) + Int64(offset) * Int64(second))
            samples.append(sample(ts: ts, swap: UInt64(10_000_000 + (offset + 10) * 5_000_000)))
        }
        XCTAssertTrue(
            annotations(samples: samples, events: events)
                .filter { $0.kind == .memoryPressure }.isEmpty,
            "swap growth alone is not memory pressure")
    }

    // MARK: Rule 3 — prefill queueing

    func testPrefillQueueingTriggers() {
        // Prefill is identical for every request. Four first outputs arrive at
        // 100 ms and one at 1 s, proving the rule uses observable TTFT rather
        // than the old prefill-end surrogate.
        var events: [EventEnvelope] = []
        for index in 0..<4 {
            let base = UInt64(index + 1) * 10 * second
            events += request(
                "q-\(index)", startTs: base, prefillTs: base + second / 20,
                endTs: base + 2 * second, firstOutputTs: base + second / 10)
        }
        let slowStart = 60 * second
        events += request(
            "q-slow", startTs: slowStart, prefillTs: slowStart + second / 20,
            endTs: slowStart + 3 * second, firstOutputTs: slowStart + second)

        let found = annotations(samples: [], events: events)
            .filter { $0.kind == .prefillQueueing }
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found[0].atNs, slowStart)
        XCTAssertEqual(found[0].evidence.values["ttftNs"], Double(second))
    }

    func testUniformTTFTDoesNotTrigger() {
        var events: [EventEnvelope] = []
        for index in 0..<5 {
            let base = UInt64(index + 1) * 10 * second
            events += request(
                "q-\(index)", startTs: base, prefillTs: base + second / 10,
                endTs: base + 2 * second)
        }
        XCTAssertTrue(
            annotations(samples: [], events: events)
                .filter { $0.kind == .prefillQueueing }.isEmpty)
    }

    // MARK: Rule 4 — KV-dominated footprint

    func testKVDominanceTriggersOncePerRequest() {
        let samples = [sample(ts: 10 * second, rss: 1_000_000_000)]
        let events = [
            tick(ts: 10 * second, tokens: 1, kv: 300_000_000),
            tick(ts: 11 * second, tokens: 2, kv: 450_000_000),
            tick(ts: 12 * second, tokens: 3, kv: 500_000_000),
        ]
        let found = annotations(samples: samples, events: events)
            .filter { $0.kind == .kvDominatedFootprint }
        XCTAssertEqual(found.count, 1, "first crossing only — not one per tick")
        XCTAssertEqual(found[0].atNs, 11 * second)
        XCTAssertEqual(found[0].evidence.values["kvCacheBytes"], 450_000_000)
    }

    func testModestKVDoesNotTrigger() {
        let samples = [sample(ts: 10 * second, rss: 1_000_000_000)]
        let events = [
            tick(ts: 10 * second, tokens: 1, kv: 100_000_000),
            tick(ts: 11 * second, tokens: 2, kv: 200_000_000),
        ]
        XCTAssertTrue(
            annotations(samples: samples, events: events)
                .filter { $0.kind == .kvDominatedFootprint }.isEmpty)
    }

    func testAllocatorGrowthProxyNeverTriggersKVDominance() {
        let samples = [sample(ts: 10 * second, rss: 1_000_000_000)]
        let proxy = EventEnvelope(
            version: EventProtocol.version, sequence: 1, ts: 10 * second,
            runId: "r-a", requestId: "q-proxy",
            payload: .decodeTick(
                DecodeTickPayload(
                    outputTokens: 1, kvCacheBytes: nil, activeMemoryBytes: 1_900_000_000,
                    allocatorMemoryGrowthBytes: 900_000_000,
                    memoryProvenance: .allocatorDeltaProxy)))
        XCTAssertTrue(
            annotations(samples: samples, events: [proxy])
                .filter { $0.kind == .kvDominatedFootprint }.isEmpty)
    }

    func testLegacyUnprovenancedMemoryNeverTriggersKVDominance() {
        let samples = [sample(ts: 10 * second, rss: 1_000_000_000)]
        let legacy = EventEnvelope(
            ts: 10 * second, runId: "r-a", requestId: "q-legacy",
            payload: .decodeTick(
                DecodeTickPayload(
                    outputTokens: 1, kvCacheBytes: 900_000_000,
                    activeMemoryBytes: 900_000_000)))
        XCTAssertTrue(
            annotations(samples: samples, events: [legacy])
                .filter { $0.kind == .kvDominatedFootprint }.isEmpty)
    }

    // MARK: Rule 5 — GPU underutilized during decode

    func testLowGPUBusyDuringDecodeTriggers() {
        let events = request(
            "q-1", startTs: 10 * second, prefillTs: 11 * second, endTs: 20 * second)
        let samples = (11...20).map {
            sample(ts: UInt64($0) * second, gpuBusy: 20)
        }
        let found = annotations(samples: samples, events: events)
            .filter { $0.kind == .gpuUnderutilized }
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found[0].atNs, 11 * second)
        XCTAssertEqual(found[0].evidence.values["meanGpuBusyPercent"] ?? 0, 20, accuracy: 0.01)
    }

    func testBusyGPUDoesNotTrigger() {
        let events = request(
            "q-1", startTs: 10 * second, prefillTs: 11 * second, endTs: 20 * second)
        let samples = (11...20).map {
            sample(ts: UInt64($0) * second, gpuBusy: 85)
        }
        XCTAssertTrue(
            annotations(samples: samples, events: events)
                .filter { $0.kind == .gpuUnderutilized }.isEmpty)
    }

    func testMissingGPUChannelsNeverTrigger() {
        // No GPU data at all (session recorded without the daemon): the rule
        // must stay silent, not read absence as 0% busy.
        let events = request(
            "q-1", startTs: 10 * second, prefillTs: 11 * second, endTs: 20 * second)
        let samples = (11...20).map { sample(ts: UInt64($0) * second, gpuBusy: nil) }
        XCTAssertTrue(
            annotations(samples: samples, events: events)
                .filter { $0.kind == .gpuUnderutilized }.isEmpty)
    }

    // MARK: Engine plumbing

    func testAnnotationsAreSortedAndEmptyInputsAreSafe() {
        XCTAssertTrue(AnnotationEngine.annotate(samples: [], events: []).isEmpty)

        let changeAt = 10 * second
        let throttleEvents =
            steadyTicks(from: changeAt - 5 * second, to: changeAt, perSecond: 20)
            + steadyTicks(from: changeAt, to: changeAt + 5 * second, perSecond: 10)
        let kvSamples = [
            sample(ts: changeAt - second, thermal: .nominal, rss: 1_000_000_000),
            sample(ts: changeAt, thermal: .serious, rss: 1_000_000_000),
        ]
        let kvEvent = tick(ts: changeAt + 2 * second, requestId: "q-9", tokens: 1, kv: 900_000_000)
        let all = AnnotationEngine.annotate(
            samples: kvSamples, events: throttleEvents + [kvEvent])
        let timestamps = all.map(\.atNs)
        XCTAssertEqual(timestamps, timestamps.sorted())
        XCTAssertGreaterThanOrEqual(all.count, 2)
    }
}
