import Foundation
import XCTest

@testable import LoupeCore
@testable import LoupeStore

extension HostFingerprint {
    static let stub = HostFingerprint(
        chip: "Test Chip", model: "Test1,1", performanceCores: 4, efficiencyCores: 4,
        memoryBytes: 16_000_000_000, osVersion: "Version 15.0", osBuild: "24A000")
}

final class LoupeStoreTests: XCTestCase {
    private var directory: URL = FileManager.default.temporaryDirectory

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("loupe-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeStore(runId: String = "run-test") throws -> SessionStore {
        try SessionStore(runId: runId, directory: directory, startedAtNs: 1_000, host: .stub)
    }

    // MARK: Migration

    func testMigrationCreatesSchemaInWALModeAndReopensCleanly() async throws {
        let store = try makeStore()
        let mode = try await store.journalMode()
        XCTAssertEqual(mode.lowercased(), "wal")

        let run = try await store.run()
        XCTAssertEqual(run?.id, "run-test")
        XCTAssertEqual(run?.startedAtNs, 1_000)
        XCTAssertEqual(run?.host, .stub)
        XCTAssertNil(run?.endedAtNs)

        // Re-opening the same file re-runs the migrator; applied migrations
        // must be skipped and the run row preserved, not duplicated.
        let reopened = try makeStore()
        let sameRun = try await reopened.run()
        XCTAssertEqual(sameRun?.startedAtNs, 1_000)

        let ended = try await store.run()?.endedAtNs
        XCTAssertNil(ended)
        try await store.end(atNs: 99_000)
        let endedAfter = try await store.run()?.endedAtNs
        XCTAssertEqual(endedAfter, 99_000)
    }

    // MARK: Inserts

    func testHundredThousandRowInsertUnderTwoSeconds() async throws {
        let store = try makeStore()
        let samples = (0..<100_000).map { index in
            SystemSample(
                system: SystemWideSample(
                    ts: UInt64(index) * 1_000, thermalState: .nominal,
                    memoryUsedBytes: 8_000_000_000, memoryFreeBytes: 4_000_000_000,
                    swapUsedBytes: 0),
                process: nil)
        }

        let clock = ContinuousClock()
        let start = clock.now
        try await store.append(samples: samples)
        let elapsed = clock.now - start

        XCTAssertLessThan(elapsed, .seconds(2), "spec budget: 100k rows in under 2s")
        let counts = try await store.counts()
        XCTAssertEqual(counts.system, 100_000)
    }

    // MARK: Queries

    func testTimeRangeQueryReturnsExactlyTheWindow() async throws {
        let store = try makeStore()
        let samples = stride(from: 100, through: 1_000, by: 100).map { ts in
            SystemSample(
                system: SystemWideSample(
                    ts: UInt64(ts), thermalState: .fair, memoryUsedBytes: UInt64(ts),
                    memoryFreeBytes: 1, swapUsedBytes: 2),
                process: ProcessSample(ts: UInt64(ts), pid: 7, cpuPercent: 50, rssBytes: 123))
        }
        try await store.append(samples: samples)

        let window = try await store.systemSamples(in: 250...750)
        XCTAssertEqual(window.map(\.ts), [300, 400, 500, 600, 700])

        // BETWEEN must be inclusive on both edges.
        let inclusive = try await store.systemSamples(in: 300...700)
        XCTAssertEqual(inclusive.map(\.ts), [300, 400, 500, 600, 700])

        let processWindow = try await store.processSamples(in: 250...350)
        XCTAssertEqual(processWindow.map(\.ts), [300])
        XCTAssertEqual(processWindow.first?.pid, 7)

        let everything = try await store.systemSamples()
        XCTAssertEqual(everything.count, 10)
        XCTAssertEqual(everything.first?.thermalState, .fair)
        XCTAssertEqual(everything.first?.gpuBusyPercent, nil)
    }

    // MARK: Events

    func testEventsRoundTripThroughStore() async throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let examples = repoRoot.appendingPathComponent("protocol/examples/v1-events.ndjson")
        let decoder = EventLineDecoder()
        let originals: [EventEnvelope] = try Data(contentsOf: examples)
            .split(separator: UInt8(ascii: "\n"))
            .compactMap { try? decoder.decode(line: Data($0)).get() }
            .map { envelope in
                // The store filters by its own run id; rebase the examples.
                EventEnvelope(
                    ts: envelope.ts, runId: "run-test", requestId: envelope.requestId,
                    payload: envelope.payload)
            }
        XCTAssertEqual(originals.count, 14)

        let store = try makeStore()
        try await store.append(events: originals)
        let restored = try await store.events()
        XCTAssertEqual(restored.count, originals.count)

        // ts UInt64.max stores as a negative bit pattern and sorts first, so
        // compare order-independently by sorting both sides the same way.
        func sorted(_ envelopes: [EventEnvelope]) -> [EventEnvelope] {
            envelopes.sorted {
                ($0.ts, $0.requestId ?? "", $0.kind.rawValue)
                    < ($1.ts, $1.requestId ?? "", $1.kind.rawValue)
            }
        }
        XCTAssertEqual(sorted(restored), sorted(originals))

        // Inclusive window: the decode_tick at exactly 5.4e9 is in.
        let window = try await store.events(in: 5_000_000_000...5_400_000_000)
        XCTAssertEqual(window.count, 4)
        XCTAssertEqual(window.map(\.kind), [.requestStart, .prefillEnd, .decodeTick, .decodeTick])
    }

    func testRunsAreIsolatedByRunId() async throws {
        let storeA = try makeStore(runId: "run-a")
        let storeB = try makeStore(runId: "run-b")
        try await storeA.append(samples: [
            SystemSample(
                system: SystemWideSample(
                    ts: 1, thermalState: .nominal, memoryUsedBytes: 1, memoryFreeBytes: 1,
                    swapUsedBytes: 0),
                process: nil)
        ])
        let fromA = try await storeA.systemSamples()
        let fromB = try await storeB.systemSamples()
        XCTAssertEqual(fromA.count, 1)
        XCTAssertEqual(fromB.count, 0)
        // Separate sessions land in separate files.
        let urlA = storeA.databaseURL
        let urlB = storeB.databaseURL
        XCTAssertNotEqual(urlA, urlB)
    }
}
