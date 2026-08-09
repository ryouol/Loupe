import Foundation
import XCTest

@testable import LoupeCore
@testable import LoupeSampler

final class CPUDeltaTrackerTests: XCTestCase {
    func testFirstSampleReportsZero() {
        var tracker = CPUDeltaTracker()
        XCTAssertEqual(tracker.percent(cpuNs: 1_000_000, wallNs: 2_000_000), 0)
    }

    func testSteadyLoadComputesPercent() {
        var tracker = CPUDeltaTracker()
        _ = tracker.percent(cpuNs: 0, wallNs: 0)
        // 50ms of CPU over 100ms of wall time = 50%.
        XCTAssertEqual(tracker.percent(cpuNs: 50_000_000, wallNs: 100_000_000), 50, accuracy: 0.001)
        // Another 200ms CPU over 100ms wall = 200% (two cores).
        XCTAssertEqual(
            tracker.percent(cpuNs: 250_000_000, wallNs: 200_000_000), 200, accuracy: 0.001)
    }

    func testCounterRegressionsReportZeroNotGarbage() {
        var tracker = CPUDeltaTracker()
        _ = tracker.percent(cpuNs: 100, wallNs: 100)
        // Same wall clock (division by zero) and a rewound CPU counter (pid
        // reuse) must both degrade to 0.
        XCTAssertEqual(tracker.percent(cpuNs: 200, wallNs: 100), 0)
        XCTAssertEqual(tracker.percent(cpuNs: 50, wallNs: 200), 0)
    }
}

final class ReplaySourceTests: XCTestCase {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private func temporaryFile(lines: [String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("loupe-test-\(UUID().uuidString).ndjson")
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func sampleLine(ts: UInt64, rss: UInt64) -> String {
        """
        {"system":{"ts":\(ts),"thermalState":"nominal","memoryUsedBytes":1024,\
        "memoryFreeBytes":2048,"swapUsedBytes":0},\
        "process":{"ts":\(ts),"pid":42,"cpuPercent":12.5,"rssBytes":\(rss)}}
        """
    }

    func testReplayTelemetryYieldsAllSamplesInOrder() async throws {
        let url = try temporaryFile(lines: [
            sampleLine(ts: 100, rss: 1), sampleLine(ts: 200, rss: 2), sampleLine(ts: 300, rss: 3),
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let source = ReplayTelemetrySource(fileURL: url)
        var collected: [SystemSample] = []
        for await sample in await source.stream() {
            collected.append(sample)
        }
        XCTAssertEqual(collected.count, 3)
        XCTAssertEqual(collected.map(\.system.ts), [100, 200, 300])
        XCTAssertEqual(collected.compactMap(\.process?.rssBytes), [1, 2, 3])
        let dropped = await source.droppedLines
        XCTAssertEqual(dropped, 0)
    }

    func testReplayTelemetryCountsGarbageLinesAndKeepsGoing() async throws {
        let url = try temporaryFile(lines: [
            sampleLine(ts: 100, rss: 1), "{broken", sampleLine(ts: 200, rss: 2),
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let source = ReplayTelemetrySource(fileURL: url)
        var count = 0
        for await _ in await source.stream() { count += 1 }
        XCTAssertEqual(count, 2)
        let dropped = await source.droppedLines
        XCTAssertEqual(dropped, 1)
    }

    func testReplayTelemetryMissingFileFinishesEmptyWithFailureRecorded() async {
        let source = ReplayTelemetrySource(
            fileURL: URL(fileURLWithPath: "/nonexistent/loupe.ndjson"))
        var count = 0
        for await _ in await source.stream() { count += 1 }
        XCTAssertEqual(count, 0)
        let failure = await source.loadFailure
        XCTAssertNotNil(failure)
    }

    func testReplayEventSourceStreamsProtocolExamples() async throws {
        let url = Self.repoRoot.appendingPathComponent("protocol/examples/v1-events.ndjson")

        let source = ReplayEventSource(fileURL: url)
        var kinds: [EventKind] = []
        for await envelope in await source.stream() {
            kinds.append(envelope.kind)
        }
        XCTAssertEqual(kinds.count, 14)
        XCTAssertEqual(kinds.first, .sessionStart)
        let drops = await source.drops
        XCTAssertEqual(drops.total, 0)
    }

    func testReplayEventSourceDropsMalformedLinesWithCounter() async throws {
        let url = Self.repoRoot.appendingPathComponent("protocol/examples/v1-malformed.ndjson")

        let source = ReplayEventSource(fileURL: url)
        var count = 0
        for await _ in await source.stream() { count += 1 }
        XCTAssertEqual(count, 0)
        let drops = await source.drops
        XCTAssertEqual(drops.total, 9)
    }
}

final class HostInfoTests: XCTestCase {
    func testFingerprintPopulatesOnAppleSilicon() {
        let fingerprint = HostInfo.fingerprint()
        XCTAssertFalse(fingerprint.chip.isEmpty)
        XCTAssertNotEqual(fingerprint.chip, "unknown")
        XCTAssertGreaterThan(fingerprint.memoryBytes, 4_000_000_000)
        XCTAssertNotEqual(fingerprint.osBuild, "unknown")
        XCTAssertFalse(fingerprint.osVersion.isEmpty)

        // Core-level sysctls don't exist inside VMs (CI runners included):
        // the fingerprint must degrade to 0 there and report real counts on
        // bare metal — same rule as IOReport keys, never assume presence.
        if sysctlKeyExists("hw.perflevel0.physicalcpu") {
            XCTAssertGreaterThan(fingerprint.performanceCores, 0)
        } else {
            XCTAssertEqual(fingerprint.performanceCores, 0)
        }
        if sysctlKeyExists("hw.perflevel1.physicalcpu") {
            XCTAssertGreaterThan(fingerprint.efficiencyCores, 0)
        } else {
            XCTAssertEqual(fingerprint.efficiencyCores, 0)
        }
    }

    private func sysctlKeyExists(_ name: String) -> Bool {
        var size = 0
        return sysctlbyname(name, nil, &size, nil, 0) == 0
    }
}

final class LiveTelemetrySourceTests: XCTestCase {
    /// Live smoke test against our own process: no root, no hardware
    /// assumptions, just "the plumbing produces plausible samples".
    func testSamplesOwnProcessWithoutRoot() async {
        let source = LiveTelemetrySource(
            targetPID: ProcessInfo.processInfo.processIdentifier,
            cadence: .milliseconds(20))
        var samples: [SystemSample] = []
        for await sample in await source.stream() {
            samples.append(sample)
            if samples.count == 3 { break }
        }

        XCTAssertEqual(samples.count, 3)
        let timestamps = samples.map(\.system.ts)
        XCTAssertEqual(timestamps, timestamps.sorted(), "timestamps must be monotonic")
        for sample in samples {
            XCTAssertGreaterThan(sample.system.memoryUsedBytes, 0)
            XCTAssertNil(sample.system.gpuBusyPercent, "GPU channels are nil until M1.2")
            let process = try? XCTUnwrap(sample.process)
            XCTAssertEqual(process?.pid, ProcessInfo.processInfo.processIdentifier)
            XCTAssertGreaterThan(process?.rssBytes ?? 0, 0)
        }
    }

    func testVanishedProcessYieldsSystemOnlySamples() async {
        // PID beyond the launchd namespace that cannot exist.
        let source = LiveTelemetrySource(targetPID: 99_999, cadence: .milliseconds(10))
        for await sample in await source.stream() {
            XCTAssertNil(sample.process)
            XCTAssertGreaterThan(sample.system.memoryUsedBytes, 0)
            break
        }
    }
}
