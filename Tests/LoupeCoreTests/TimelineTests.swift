import XCTest

@testable import LoupeCore

final class DownsampleTests: XCTestCase {
    private struct Point: Equatable {
        let x: Double
        let y: Double
    }

    func testEndpointsAreAlwaysPreserved() {
        let points = (0..<1_000).map { Point(x: Double($0), y: sin(Double($0) / 20)) }
        let sampled = Downsample.lttb(points, to: 100, x: { $0.x }, y: { $0.y })
        XCTAssertEqual(sampled.count, 100)
        XCTAssertEqual(sampled.first, points.first)
        XCTAssertEqual(sampled.last, points.last)
    }

    func testPeaksArePreserved() {
        // Flat signal with one violent spike: uniform decimation would lose
        // it; LTTB must keep the exact spike point.
        var points = (0..<2_000).map { Point(x: Double($0), y: 1.0) }
        points[777] = Point(x: 777, y: 500)
        let sampled = Downsample.lttb(points, to: 50, x: { $0.x }, y: { $0.y })
        XCTAssertTrue(
            sampled.contains(Point(x: 777, y: 500)),
            "the spike must survive downsampling")
    }

    func testThresholdAtOrAboveCountIsIdentity() {
        let points = (0..<10).map { Point(x: Double($0), y: Double($0 * $0)) }
        XCTAssertEqual(Downsample.lttb(points, to: 10, x: { $0.x }, y: { $0.y }), points)
        XCTAssertEqual(Downsample.lttb(points, to: 50, x: { $0.x }, y: { $0.y }), points)
    }

    func testXOrderIsPreserved() {
        let points = (0..<5_000).map {
            Point(x: Double($0), y: Double.random(in: 0...100))
        }
        let sampled = Downsample.lttb(points, to: 200, x: { $0.x }, y: { $0.y })
        let xs = sampled.map(\.x)
        XCTAssertEqual(xs, xs.sorted(), "downsampling must never reorder time")
        XCTAssertEqual(sampled.count, 200)
    }
}

final class TimelineMergeTests: XCTestCase {
    private func sample(ts: UInt64) -> SystemSample {
        SystemSample(
            system: SystemWideSample(
                ts: ts, thermalState: .nominal, memoryUsedBytes: 1, memoryFreeBytes: 1,
                swapUsedBytes: 0),
            process: nil)
    }

    private func event(ts: UInt64, requestId: String? = "q-1") -> EventEnvelope {
        EventEnvelope(
            ts: ts, runId: "r-merge", requestId: requestId,
            payload: .decodeTick(
                DecodeTickPayload(outputTokens: 1, kvCacheBytes: 1, activeMemoryBytes: 1)))
    }

    func testKnownFortyMillisecondOffsetInterleavesCorrectly() {
        // Samples every 100ms on the daemon clock; events on an adapter clock
        // running 40ms ahead (offset = +40ms), emitted 50ms after each sample
        // in real time — so they appear at +90ms on the adapter's clock.
        let offset: Int64 = 40_000_000
        let samples = (0..<5).map { sample(ts: UInt64($0) * 100_000_000) }
        let events = (0..<5).map {
            event(ts: UInt64($0) * 100_000_000 + 50_000_000 + UInt64(offset))
        }

        let merged = TimelineMerge.merge(
            samples: samples, events: events, eventClockOffsetNs: offset)

        XCTAssertEqual(merged.count, 10)
        for (index, item) in merged.enumerated() {
            if index % 2 == 0 {
                guard case .sample = item else {
                    return XCTFail("index \(index) should be a sample")
                }
            } else {
                guard case .event = item else {
                    return XCTFail("index \(index) should be an event")
                }
                // The unified timestamp is the true emission time: +50ms.
                XCTAssertEqual(item.ts % 100_000_000, 50_000_000)
            }
        }
    }

    func testEqualTimestampsPutSampleBeforeEvent() {
        let merged = TimelineMerge.merge(
            samples: [sample(ts: 500)], events: [event(ts: 500)], eventClockOffsetNs: 0)
        guard case .sample = merged[0], case .event = merged[1] else {
            return XCTFail("state must come before the transition at equal ts")
        }
    }

    func testOffsetFromClockSyncEventsPicksBestEstimate() {
        let noisy = EventEnvelope(
            ts: 1, runId: "r", requestId: nil,
            payload: .clockSync(ClockSyncPayload(t0: 0, t1: 1_040, t2: 1_060, t3: 2_000)))
        let tight = EventEnvelope(
            ts: 2, runId: "r", requestId: nil,
            payload: .clockSync(ClockSyncPayload(t0: 10_000, t1: 10_045, t2: 10_050, t3: 10_010)))
        // tight: RTT = 10 − 5 = 5, offset = (45 + 40) / 2 ≈ 42.
        XCTAssertEqual(
            TimelineMerge.offset(fromClockSyncEvents: [noisy, tight]), 42)
        XCTAssertEqual(TimelineMerge.offset(fromClockSyncEvents: []), 0)
    }

    func testPathologicalOffsetsClampInsteadOfWrapping() {
        XCTAssertEqual(TimelineMerge.shifted(100, byRemovingOffset: 500), 0)
        XCTAssertEqual(
            TimelineMerge.shifted(UInt64.max - 10, byRemovingOffset: -500), UInt64.max)
        XCTAssertEqual(TimelineMerge.shifted(1_000, byRemovingOffset: 400), 600)
        XCTAssertEqual(TimelineMerge.shifted(1_000, byRemovingOffset: -400), 1_400)
    }
}
