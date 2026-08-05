import XCTest

@testable import LoupeApp
@testable import LoupeCore

@MainActor
final class LoupeAppTests: XCTestCase {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

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
            #"{"v":1,"ts":1100,"runId":"r","requestId":"q-1","event":"decode_tick","payload":{"outputTokens":1,"kvCacheBytes":2,"activeMemoryBytes":3}}"#,
            #"{"v":1,"ts":1200,"runId":"r","requestId":"q-1","event":"request_end","payload":{"outputTokens":1,"finishReason":"stop"}}"#,
        ]
        try eventLines.joined(separator: "\n")
            .write(toFile: base + ".ndjson", atomically: true, encoding: .utf8)

        let model = ReplayViewModel(basePath: base)
        await model.load()

        XCTAssertTrue(model.isLoaded)
        XCTAssertEqual(model.samples.count, 5)
        XCTAssertEqual(model.totalEventCount, 3)
        XCTAssertEqual(model.decodeTickCount, 1)
        XCTAssertEqual(model.milestones.count, 2)
        XCTAssertEqual(model.chartPoints.count, 5)
        XCTAssertEqual(model.thermalStatesSeen, [.nominal])
    }

    func testViewModelSurfacesMissingFixture() async {
        let model = ReplayViewModel(basePath: "/definitely/not/here/base")
        await model.load()
        XCTAssertFalse(model.isLoaded)
        XCTAssertNotNil(model.loadFailure)
    }
}
