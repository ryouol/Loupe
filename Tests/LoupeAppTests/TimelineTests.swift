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
        // Endpoints survive downsampling.
        XCTAssertEqual(model.chartPoints.first?.seconds, 0)
        XCTAssertEqual(model.chartPoints.last?.seconds ?? 0, model.durationSeconds)
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
