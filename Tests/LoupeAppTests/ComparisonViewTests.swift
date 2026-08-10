import SwiftUI
import XCTest

@testable import LoupeApp
@testable import LoupeBench
@testable import LoupeCore

@MainActor
final class ComparisonViewTests: XCTestCase {
    private static let realReport = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("fixtures/benchmark-baseline.report.json")

    private func mismatchedReportURL() throws -> URL {
        let original = try BenchmarkAssembler.decode(Data(contentsOf: Self.realReport))
        var spec = original.spec
        spec.quantization = "8bit"
        let altered = BenchmarkReport(
            formatVersion: original.formatVersion, spec: spec, host: original.host,
            createdAtNs: original.createdAtNs, contexts: original.contexts)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("loupe-mismatch-\(UUID().uuidString).json")
        try BenchmarkAssembler.encode(altered).write(to: url)
        return url
    }

    func testIdenticalReportsCompareWithZeroDeltas() {
        let model = ComparisonViewModel()
        model.load(url: Self.realReport, asBaseline: true)
        model.load(url: Self.realReport, asBaseline: false)

        let comparison = model.comparison
        XCTAssertTrue(comparison?.isComparable ?? false)
        XCTAssertEqual(comparison?.deltas?.count, 4, "two contexts x two metrics")
        for delta in comparison?.deltas ?? [] {
            XCTAssertEqual(delta.deltaPercent, 0, accuracy: 0.000001)
        }
    }

    func testMismatchedReportsBlockWithBannerData() throws {
        let model = ComparisonViewModel()
        model.load(url: Self.realReport, asBaseline: true)
        model.load(url: try mismatchedReportURL(), asBaseline: false)

        let comparison = try XCTUnwrap(model.comparison)
        XCTAssertFalse(comparison.isComparable)
        XCTAssertNil(comparison.deltas)
        XCTAssertEqual(comparison.mismatches.map(\.name), ["quantization"])

        // Exports mirror the refusal: mismatch rows, never deltas.
        let csv = try XCTUnwrap(model.exportCSV())
        XCTAssertTrue(csv.hasPrefix("mismatched_dimension,"))
        XCTAssertTrue(csv.contains("quantization,4bit,8bit"))
        XCTAssertFalse(csv.contains("delta_percent"))
    }

    func testComparableExportsCarryDeltas() throws {
        let model = ComparisonViewModel()
        model.load(url: Self.realReport, asBaseline: true)
        model.load(url: Self.realReport, asBaseline: false)

        let csv = try XCTUnwrap(model.exportCSV())
        XCTAssertTrue(csv.hasPrefix("context_tokens,metric,"))
        XCTAssertTrue(csv.contains("64,decode tok/s,"))
        XCTAssertTrue(csv.contains("256,TTFT ms,"))

        let json = try XCTUnwrap(model.exportJSON())
        let payload = try JSONDecoder().decode(ComparisonExport.JSONPayload.self, from: json)
        XCTAssertTrue(payload.comparable)
        XCTAssertEqual(payload.deltas?.count, 4)
        XCTAssertTrue(payload.mismatches.isEmpty)
    }

    func testComparisonViewRendersBothStates() {
        for width in [700.0, 1_100.0] {
            let renderer = ImageRenderer(
                content: ComparisonView().frame(width: width, height: 600))
            renderer.proposedSize = ProposedViewSize(width: width, height: 600)
            XCTAssertNotNil(renderer.nsImage)
        }
    }
}
