import XCTest

@testable import LoupeApp
@testable import LoupeCore

@MainActor
final class LoupeAppTests: XCTestCase {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private func provenance(_ csv: String) -> [String: String] {
        Dictionary(
            uniqueKeysWithValues: csv.split(separator: "\n").compactMap { row in
                let cells = row.split(separator: ",", omittingEmptySubsequences: false)
                guard cells.count >= 3, cells[0] == "provenance" else { return nil }
                return (String(cells[1]), String(cells[2]))
            })
    }

    func testRootViewInstantiates() {
        _ = RootView()
        _ = RootView(replayBasePath: "/tmp/nope")
    }

    /// Headless version of `make replay`: the committed baseline fixture must
    /// load through the real replay sources with zero drops.
    func testBaselineFixtureLoadsEndToEnd() async {
        let base = Self.repoRoot.appendingPathComponent("fixtures/baseline-session").path
        let model = ReplayViewModel(basePath: base)
        await model.load()

        XCTAssertTrue(model.isLoaded, model.loadFailure ?? "unknown load failure")
        XCTAssertGreaterThan(model.samples.count, 100, "expected ~60s of 10 Hz samples")
        XCTAssertGreaterThan(model.decodeTickCount, 50, "expected a real decode trace")
        XCTAssertEqual(model.sampleDrops, 0, "golden fixture must decode cleanly")
        XCTAssertEqual(model.eventDrops, 0, "golden fixture must decode cleanly")
        XCTAssertFalse(model.milestones.isEmpty)
        XCTAssertFalse(model.chartPoints.isEmpty)

        let timestamps = model.samples.map(\.system.ts)
        XCTAssertEqual(timestamps, timestamps.sorted(), "system samples must be time-ordered")

        let kinds = Set(model.milestones.map(\.kind))
        XCTAssertTrue(kinds.contains(.sessionStart))
        XCTAssertTrue(kinds.contains(.modelLoadEnd))
        XCTAssertTrue(kinds.contains(.requestEnd))
    }

    func testViewModelLoadsSyntheticFixturePair() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("loupe-vm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let base = directory.appendingPathComponent("mini").path

        let systemLines = (0..<5).map { index in
            """
            {"system":{"ts":\(1_000 + index * 100),"thermalState":"nominal",\
            "memoryUsedBytes":100,"memoryFreeBytes":50,"swapUsedBytes":0},"process":null}
            """
        }
        try systemLines.joined(separator: "\n")
            .write(toFile: base + ".system.ndjson", atomically: true, encoding: .utf8)
        let eventLines = [
            #"{"v":1,"ts":1000,"runId":"r","event":"session_start","payload":{"adapter":"a","adapterVersion":"1","runtime":"mlx","pid":9}}"#,
            #"{"v":1,"ts":1050,"runId":"r","requestId":"q-1","event":"request_start","payload":{"promptTokens":1}}"#,
            #"{"v":1,"ts":1100,"runId":"r","requestId":"q-1","event":"prefill_end","payload":{"promptTokens":1}}"#,
            #"{"v":1,"ts":1150,"runId":"r","requestId":"q-1","event":"decode_tick","payload":{"outputTokens":1,"kvCacheBytes":2,"activeMemoryBytes":3}}"#,
            #"{"v":1,"ts":1200,"runId":"r","requestId":"q-1","event":"request_end","payload":{"outputTokens":1,"finishReason":"stop"}}"#,
        ]
        try eventLines.joined(separator: "\n")
            .write(toFile: base + ".ndjson", atomically: true, encoding: .utf8)
        let metadata = SessionAcquisitionMetadata(
            eventLosses: AcquisitionLossCount(
                exact: 2, lowerBound: 2, breakdown: ["producer_reported": 2]),
            telemetryLosses: AcquisitionLossCount(
                exact: 1, lowerBound: 1, breakdown: ["event_buffer": 1]))
        try JSONEncoder.deterministic().encode(metadata).write(
            to: URL(fileURLWithPath: base + SessionFilePair.metadataSuffix))

        let model = ReplayViewModel(basePath: base)
        await model.load()

        XCTAssertTrue(model.isLoaded)
        XCTAssertEqual(model.samples.count, 5)
        XCTAssertEqual(model.totalEventCount, 5)
        XCTAssertEqual(model.decodeTickCount, 1)
        XCTAssertEqual(model.milestones.count, 4)
        XCTAssertEqual(model.chartPoints.count, 5)
        XCTAssertEqual(model.thermalStatesSeen, [.nominal])
        XCTAssertEqual(model.acquisitionMetadata, metadata)
        let report = try JSONDecoder().decode(
            SessionEvidenceReport.self, from: model.evidenceJSON())
        XCTAssertEqual(report.schemaVersion, 2)
        XCTAssertEqual(report.sessionName, "mini")
        XCTAssertEqual(report.eventSource.filename, "mini.ndjson")
        XCTAssertEqual(report.eventSource.sha256.count, 64)
        XCTAssertEqual(report.telemetrySource.filename, "mini.system.ndjson")
        XCTAssertEqual(report.telemetrySource.sha256.count, 64)
        XCTAssertEqual(report.acquisitionSource?.filename, "mini.metadata.json")
        XCTAssertEqual(report.acquisitionSource?.sha256.count, 64)
        XCTAssertEqual(report.durationSeconds, 0.000_000_4, accuracy: 0.000_000_001)
        XCTAssertEqual(report.eventCount, 5)
        XCTAssertEqual(report.sampleCount, 5)
        XCTAssertEqual(report.droppedEventLines, 0)
        XCTAssertEqual(report.droppedSampleLines, 0)
        XCTAssertEqual(report.eventAcquisitionLosses, metadata.eventLosses)
        XCTAssertEqual(report.telemetryAcquisitionLosses, metadata.telemetryLosses)
        XCTAssertEqual(report.thermalStates, ["nominal"])
        let csv = try model.evidenceCSV()
        let csvProvenance = provenance(csv)
        XCTAssertEqual(csvProvenance.count, 21)
        XCTAssertEqual(csvProvenance["schema_version"], String(report.schemaVersion))
        XCTAssertNotNil(ISO8601DateFormatter().date(from: csvProvenance["generated_at"] ?? ""))
        XCTAssertEqual(csvProvenance["session_name"], report.sessionName)
        XCTAssertEqual(csvProvenance["event_source_filename"], report.eventSource.filename)
        XCTAssertEqual(csvProvenance["event_source_sha256"], report.eventSource.sha256)
        XCTAssertEqual(
            csvProvenance["telemetry_source_filename"], report.telemetrySource.filename)
        XCTAssertEqual(csvProvenance["telemetry_source_sha256"], report.telemetrySource.sha256)
        XCTAssertEqual(
            csvProvenance["acquisition_source_filename"], report.acquisitionSource?.filename)
        XCTAssertEqual(
            csvProvenance["acquisition_source_sha256"], report.acquisitionSource?.sha256)
        XCTAssertEqual(
            csvProvenance["duration_seconds"],
            String(
                format: "%.6f", locale: Locale(identifier: "en_US_POSIX"),
                report.durationSeconds))
        XCTAssertEqual(csvProvenance["event_count"], "5")
        XCTAssertEqual(csvProvenance["sample_count"], "5")
        XCTAssertEqual(csvProvenance["replay_event_parser_drops"], "0")
        XCTAssertEqual(csvProvenance["replay_telemetry_parser_drops"], "0")
        XCTAssertEqual(csvProvenance["event_acquisition_exact"], "2")
        XCTAssertEqual(csvProvenance["event_acquisition_lower_bound"], "2")
        XCTAssertEqual(csvProvenance["event_acquisition_breakdown"], "producer_reported=2")
        XCTAssertEqual(csvProvenance["telemetry_acquisition_exact"], "1")
        XCTAssertEqual(csvProvenance["telemetry_acquisition_lower_bound"], "1")
        XCTAssertEqual(csvProvenance["telemetry_acquisition_breakdown"], "event_buffer=1")
        XCTAssertEqual(csvProvenance["thermal_states"], "nominal")

        var modifiedMetadata = try JSONEncoder.deterministic().encode(metadata)
        modifiedMetadata.append(UInt8(ascii: " "))
        try modifiedMetadata.write(
            to: URL(fileURLWithPath: base + SessionFilePair.metadataSuffix))
        XCTAssertThrowsError(try model.evidenceJSON())
        try JSONEncoder.deterministic().encode(metadata).write(
            to: URL(fileURLWithPath: base + SessionFilePair.metadataSuffix))

        try (eventLines.joined(separator: "\n") + "\n")
            .write(toFile: base + ".ndjson", atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try model.evidenceJSON())
    }

    func testViewModelSurfacesMissingFixture() async {
        let model = ReplayViewModel(basePath: "/definitely/not/here/base")
        await model.load()
        XCTAssertFalse(model.isLoaded)
        XCTAssertNotNil(model.loadFailure)
    }

    func testBundledSampleLoadsAndExportsHashedEvidence() async throws {
        let base = try XCTUnwrap(SampleSession.basePath())
        let model = ReplayViewModel(basePath: base)
        await model.load()
        XCTAssertTrue(model.isLoaded, model.loadFailure ?? "sample load failed")
        XCTAssertEqual(model.eventDrops, 0)
        XCTAssertEqual(model.sampleDrops, 0)
        XCTAssertGreaterThanOrEqual(model.requestMetrics.count, 2)

        let report = try JSONDecoder().decode(
            SessionEvidenceReport.self, from: model.evidenceJSON())
        XCTAssertEqual(report.schemaVersion, 2)
        XCTAssertEqual(report.eventSource.sha256.count, 64)
        XCTAssertEqual(report.telemetrySource.sha256.count, 64)
        XCTAssertEqual(report.eventCount, 16)
        XCTAssertEqual(report.sampleCount, 20)
        XCTAssertNil(report.eventAcquisitionLosses)
        XCTAssertNil(report.telemetryAcquisitionLosses)
        XCTAssertNil(report.acquisitionSource)
        XCTAssertEqual(model.acquisitionLossDisplay, "unknown")
        let csv = try model.evidenceCSV()
        let csvProvenance = provenance(csv)
        XCTAssertEqual(csvProvenance.count, 21)
        XCTAssertEqual(csvProvenance["event_source_filename"], "demo-session.ndjson")
        XCTAssertEqual(csvProvenance["event_source_sha256"], report.eventSource.sha256)
        XCTAssertEqual(csvProvenance["telemetry_source_sha256"], report.telemetrySource.sha256)
        XCTAssertEqual(csvProvenance["event_count"], "16")
        XCTAssertEqual(csvProvenance["sample_count"], "20")
        XCTAssertEqual(csvProvenance["event_acquisition_exact"], "unknown")
        XCTAssertEqual(csvProvenance["event_acquisition_lower_bound"], "unknown")
        XCTAssertEqual(csvProvenance["acquisition_source_filename"], "unknown")
        XCTAssertEqual(csvProvenance["acquisition_source_sha256"], "unknown")
        XCTAssertTrue(csv.contains("request,,,q-1"))
    }

    func testEvidenceCSVNeutralizesSpreadsheetFormulaCells() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("loupe-evidence-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let base = directory.appendingPathComponent("formula").path
        let events = [
            #"{"v":1,"ts":1000,"runId":"r","event":"session_start","payload":{"adapter":"a","adapterVersion":"1","runtime":"mlx","pid":9}}"#,
            #"{"v":1,"ts":1010,"runId":"r","requestId":"\t=2+2","event":"request_start","payload":{"promptTokens":1}}"#,
            #"{"v":1,"ts":1020,"runId":"r","requestId":"\t=2+2","event":"prefill_end","payload":{"promptTokens":1}}"#,
            #"{"v":1,"ts":1030,"runId":"r","requestId":"\t=2+2","event":"request_end","payload":{"outputTokens":1,"finishReason":"stop"}}"#,
        ]
        try events.joined(separator: "\n")
            .write(toFile: base + ".ndjson", atomically: true, encoding: .utf8)
        try
            #"{"system":{"ts":1000,"thermalState":"nominal","memoryUsedBytes":100,"memoryFreeBytes":50,"swapUsedBytes":0},"process":null}"#
            .write(toFile: base + ".system.ndjson", atomically: true, encoding: .utf8)

        let model = ReplayViewModel(basePath: base)
        await model.load()
        XCTAssertTrue(model.isLoaded)
        XCTAssertTrue(try model.evidenceCSV().contains("request,,,'\t=2+2"))
    }
}
