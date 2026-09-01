import SwiftUI
import XCTest

@testable import LoupeApp
@testable import LoupeCore

final class TimelineGeometryTests: XCTestCase {
    func testSequentialSpansShareLaneZero() {
        let lanes = TimelineGeometry.packLanes([
            (start: 0, end: 1), (start: 1.5, end: 2), (start: 2.5, end: 3),
        ])
        XCTAssertEqual(lanes, [0, 0, 0])
    }

    func testOverlappingSpansStack() {
        let lanes = TimelineGeometry.packLanes([
            (start: 0, end: 10), (start: 2, end: 5), (start: 6, end: 12), (start: 11, end: 13),
        ])
        XCTAssertEqual(lanes, [0, 1, 1, 0])
    }

    func testNearestIndexBinarySearch() {
        let seconds: [Double] = [0, 1, 2, 3, 4]
        XCTAssertEqual(TimelineGeometry.nearestIndex(in: seconds, to: -5), 0)
        XCTAssertEqual(TimelineGeometry.nearestIndex(in: seconds, to: 1.4), 1)
        XCTAssertEqual(TimelineGeometry.nearestIndex(in: seconds, to: 1.6), 2)
        XCTAssertEqual(TimelineGeometry.nearestIndex(in: seconds, to: 99), 4)
        XCTAssertNil(TimelineGeometry.nearestIndex(in: [], to: 1))
    }
}

@MainActor
final class TimelineAlignmentTests: XCTestCase {
    private static let base = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("fixtures/baseline-session").path

    private func loadedModel() async -> ReplayViewModel {
        let model = ReplayViewModel(basePath: Self.base)
        await model.load()
        return model
    }

    func testSpansCoverEveryCompletedRequest() async {
        let model = await loadedModel()
        XCTAssertEqual(model.requestSpans.count, 105)
        for span in model.requestSpans {
            XCTAssertLessThanOrEqual(span.startSeconds, span.prefillEndSeconds)
            XCTAssertLessThanOrEqual(span.prefillEndSeconds, span.endSeconds)
            XCTAssertEqual(span.lane, 0, "sequential requests all pack into lane 0")
        }
        XCTAssertGreaterThan(model.durationSeconds, 60)
    }

    /// The scrubber contract: every lane's readout at scrub position t comes
    /// from the same chart point and the same span lookup.
    func testScrubReadoutIsConsistentAcrossLanes() async {
        let model = await loadedModel()
        for fraction in [0.1, 0.37, 0.5, 0.83] {
            let target = model.durationSeconds * fraction
            guard let readout = model.readout(at: target) else {
                return XCTFail("readout must exist inside the session")
            }
            // The readout's timestamp is the nearest sampled point…
            let index = TimelineGeometry.nearestIndex(
                in: model.chartPoints.map(\.seconds), to: target)
            let point = model.chartPoints[index ?? 0]
            XCTAssertEqual(readout.seconds, point.seconds)
            XCTAssertEqual(readout.systemUsedGB, point.systemUsedGB)
            XCTAssertEqual(readout.processRSSGB, point.processRSSGB)
            // …and the active request agrees with the swimlane geometry.
            let span = TimelineGeometry.activeSpan(in: model.requestSpans, at: target)
            XCTAssertEqual(readout.activeRequestId, span?.id)
        }
    }

    func testChartSeriesAreCappedByLTTB() async {
        let model = await loadedModel()
        XCTAssertLessThanOrEqual(model.chartPoints.count, 2_000)
        XCTAssertFalse(model.chartPoints.isEmpty)
        // Endpoints survive downsampling, and no lane extends past duration.
        XCTAssertLessThanOrEqual(
            model.chartPoints.last?.seconds ?? 0, model.durationSeconds + 0.0001)
    }

    /// Charts, swimlanes, and annotations must share one time zero — two
    /// different zeros on one axis was an actual bug this pins against.
    func testEveryLaneSharesOneTimeZero() async {
        let model = await loadedModel()
        let firstChart = model.chartPoints.first?.seconds ?? .infinity
        let firstMilestone = model.milestones.first?.offsetSeconds ?? .infinity
        XCTAssertEqual(min(firstChart, firstMilestone), 0, accuracy: 0.000001)
        XCTAssertGreaterThanOrEqual(firstChart, 0)
        XCTAssertGreaterThanOrEqual(firstMilestone, 0)
        for span in model.requestSpans {
            XCTAssertGreaterThanOrEqual(span.startSeconds, 0)
            XCTAssertLessThanOrEqual(span.endSeconds, model.durationSeconds + 0.0001)
        }
        for annotation in model.annotations {
            XCTAssertGreaterThanOrEqual(annotation.atSeconds, 0)
            XCTAssertLessThanOrEqual(annotation.atSeconds, model.durationSeconds + 0.0001)
        }
    }

    /// M2.1 acceptance, at the shipping surface: a session whose adapter
    /// clock runs 40ms ahead (declared via clock_sync) must land its events
    /// on the sample clock — correct interleave, no 40ms skew.
    func testKnownFortyMillisecondOffsetAlignsThroughTheAssembler() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("loupe-offset-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let base = directory.appendingPathComponent("offset40").path

        // Samples every 100ms on the daemon clock, starting at t=1s.
        let systemLines = (0..<10).map { index in
            """
            {"system":{"ts":\(1_000_000_000 + index * 100_000_000),"thermalState":"nominal",\
            "memoryUsedBytes":100,"memoryFreeBytes":50,"swapUsedBytes":0},"process":null}
            """
        }
        try systemLines.joined(separator: "\n")
            .write(toFile: base + ".system.ndjson", atomically: true, encoding: .utf8)

        // Adapter clock = daemon clock + 40ms (clock_sync: symmetric 2ms
        // paths, so t1/t2 sit offset+delay ahead). request_start truly fires
        // 250ms after the first sample → adapter stamps it at +290ms.
        let offset: UInt64 = 40_000_000
        let syncT0: UInt64 = 1_000_000_000
        let eventLines = [
            #"{"v":1,"ts":\#(syncT0 + offset),"runId":"r-o","event":"session_start","payload":{"adapter":"test","adapterVersion":"1","runtime":"mlx","pid":9}}"#,
            #"{"v":1,"ts":\#(syncT0 + offset + 2_000_000),"runId":"r-o","event":"clock_sync","payload":{"t0":\#(syncT0),"t1":\#(syncT0 + offset + 2_000_000),"t2":\#(syncT0 + offset + 2_500_000),"t3":\#(syncT0 + 4_500_000)}}"#,
            #"{"v":1,"ts":\#(1_250_000_000 + offset),"runId":"r-o","requestId":"q-1","event":"request_start","payload":{}}"#,
            #"{"v":1,"ts":\#(1_350_000_000 + offset),"runId":"r-o","requestId":"q-1","event":"prefill_end","payload":{"promptTokens":8}}"#,
            #"{"v":1,"ts":\#(1_650_000_000 + offset),"runId":"r-o","requestId":"q-1","event":"request_end","payload":{"outputTokens":4,"finishReason":"stop"}}"#,
        ]
        try eventLines.joined(separator: "\n")
            .write(toFile: base + ".ndjson", atomically: true, encoding: .utf8)

        let model = ReplayViewModel(basePath: base)
        await model.load()
        XCTAssertTrue(model.isLoaded)

        // Estimated offset ≈ 40ms ± the 250µs of path asymmetry; events must
        // land at their true daemon-clock moments, not 40ms late.
        let start = model.milestones.first { $0.kind == .requestStart }
        XCTAssertEqual(start?.offsetSeconds ?? -1, 0.25, accuracy: 0.005)
        let span = model.requestSpans.first
        XCTAssertEqual(span?.startSeconds ?? -1, 0.25, accuracy: 0.005)
        XCTAssertEqual(span?.endSeconds ?? -1, 0.65, accuracy: 0.005)
        // Interleave: the request starts between samples 2 and 3 (0.2/0.3s).
        XCTAssertGreaterThan(start?.offsetSeconds ?? -1, 0.2)
        XCTAssertLessThan(start?.offsetSeconds ?? -1, 0.3)
    }

    func testTimelineRendersAtThreeWindowWidths() async {
        let model = await loadedModel()
        XCTAssertTrue(model.isLoaded)
        for width in [720.0, 1_000.0, 1_400.0] {
            let renderer = ImageRenderer(
                content: ReplayView(basePath: Self.base)
                    .frame(width: width, height: 1_200))
            renderer.proposedSize = ProposedViewSize(width: width, height: 1_200)
            let image = renderer.nsImage
            XCTAssertNotNil(image, "timeline must render at width \(width)")
            XCTAssertEqual(image?.size.width ?? 0, width, accuracy: 1.0)
        }
    }
}
