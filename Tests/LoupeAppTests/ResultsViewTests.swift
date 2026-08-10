import SwiftUI
import XCTest

@testable import LoupeApp
@testable import LoupeBench

/// Render tests use ImageRenderer rather than pixel-snapshot files: pixel
/// baselines diverge across macOS releases on CI, so these assert the view
/// hierarchy renders to real images at several widths while the view-model
/// tests pin the numbers the charts draw.
@MainActor
final class ResultsViewTests: XCTestCase {
    private static let reportURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("fixtures/benchmark-baseline.report.json")

    func testViewModelDerivesSweepFromRealReport() {
        let model = ResultsViewModel()
        model.load(url: Self.reportURL)

        XCTAssertNil(model.loadFailure)
        XCTAssertEqual(model.sweep.map(\.contextTokens), [64, 256])
        for point in model.sweep {
            XCTAssertGreaterThan(point.decode.p50, 0)
            XCTAssertGreaterThan(point.ttft.p50, 0)
            XCTAssertEqual(point.decode.count, 2, "two measured runs per context")
        }
        // Physics: longer prompts take longer to prefill.
        XCTAssertLessThan(model.sweep[0].ttft.p50, model.sweep[1].ttft.p50)
        XCTAssertEqual(model.runRows.count, 4)
        XCTAssertEqual(model.reportName, "benchmark-baseline.report")
    }

    func testViewModelSurfacesUnreadableReport() {
        let model = ResultsViewModel()
        model.load(url: URL(fileURLWithPath: "/nope/missing.json"))
        XCTAssertNotNil(model.loadFailure)
        XCTAssertNil(model.report)
        XCTAssertTrue(model.sweep.isEmpty)
    }

    func testResultsViewRendersAtThreeWidths() {
        let model = ResultsViewModel()
        model.load(url: Self.reportURL)
        XCTAssertNil(model.loadFailure)

        for width in [640.0, 900.0, 1_280.0] {
            let renderer = ImageRenderer(
                content: ResultsView()
                    .frame(width: width, height: 900))
            renderer.proposedSize = ProposedViewSize(width: width, height: 900)
            let image = renderer.nsImage
            XCTAssertNotNil(image, "results view must render at width \(width)")
            XCTAssertEqual(image?.size.width ?? 0, width, accuracy: 1.0)
        }
    }

    func testSessionRequestMetricsRenderFromBaselineSession() async {
        let base = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("fixtures/baseline-session").path
        let model = ReplayViewModel(basePath: base)
        await model.load()

        XCTAssertEqual(model.requestMetrics.count, 105, "the baseline session has 105 requests")
        for metrics in model.requestMetrics {
            XCTAssertGreaterThan(metrics.ttftNs, 0)
            XCTAssertGreaterThan(metrics.decodeTokensPerSecond, 0)
        }
    }
}
