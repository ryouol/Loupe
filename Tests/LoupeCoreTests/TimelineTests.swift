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
    // The known-40ms-offset interleave acceptance lives with the timeline
    // assembler tests in LoupeAppTests — the offset is verified through the
    // real render path, not a parallel merge that nothing ships.

    func testKnownOffsetMapsEventsOntoSampleClock() {
        // Adapter clock runs 40ms ahead: an event emitted 50ms after a
        // sample carries ts +90ms and must read back as +50ms unified.
        let offset: Int64 = 40_000_000
        XCTAssertEqual(
            TimelineMerge.shifted(90_000_000, byRemovingOffset: offset), 50_000_000)
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
