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
    private var storageID = UUID()

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("loupe-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        storageID = UUID()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeStore(runId: String = "run-test") throws -> SessionStore {
        try SessionStore(
            storageID: storageID, runId: runId, directory: directory,
            startedAtNs: 1_000, host: .stub)
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

    func testStoreRejectsInvalidTelemetry() async throws {
        let store = try makeStore()
        let invalid = SystemSample(
            system: SystemWideSample(
                ts: 1, thermalState: .nominal, memoryUsedBytes: 1,
                memoryFreeBytes: 1, swapUsedBytes: 0, gpuBusyPercent: -1),
            process: nil)

        do {
            try await store.append(samples: [invalid])
            XCTFail("Expected invalid telemetry to be rejected")
        } catch {
            XCTAssertEqual(error as? StoreError, .invalidSample)
        }
        let counts = try await store.counts()
        XCTAssertEqual(counts.system, 0)
    }

    func testStoreRejectsEventThatBypassesProtocolLimits() async throws {
        let store = try makeStore()
        let invalid = EventEnvelope(
            ts: 1, runId: "run-test", requestId: nil,
            payload: .modelLoadStart(
                .init(modelId: String(repeating: "m", count: 1_025))))

        do {
            try await store.append(events: [invalid])
            XCTFail("Expected an invalid event to be rejected")
        } catch {
            XCTAssertEqual(error as? StoreError, .invalidEvent)
        }
        let counts = try await store.counts()
        XCTAssertEqual(counts.events, 0)
    }

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
        XCTAssertEqual(restored, originals)

        // Inclusive window: the decode_tick at exactly 5.4e9 is in.
        let window = try await store.events(in: 5_000_000_000...5_400_000_000)
        XCTAssertEqual(window.count, 4)
        XCTAssertEqual(window.map(\.kind), [.requestStart, .prefillEnd, .decodeTick, .decodeTick])

        let crossing = try await store.events(in: 5_400_000_000...UInt64.max)
        XCTAssertEqual(crossing.last?.ts, UInt64.max)
    }

    func testStoreRejectsEventsForAnotherRun() async throws {
        let store = try makeStore()
        let event = EventEnvelope(
            ts: 1, runId: "another-run", requestId: nil,
            payload: .sessionStart(
                .init(adapter: "test", adapterVersion: "1", runtime: "test", pid: 1)))

        do {
            try await store.append(events: [event])
            XCTFail("Expected the store to reject an event for another run")
        } catch {
            XCTAssertEqual(error as? StoreError, .unexpectedRunID("another-run"))
        }
        let counts = try await store.counts()
        XCTAssertEqual(counts.events, 0)
    }

    func testRunsAreIsolatedByRunId() async throws {
        let storeA = try makeStore(runId: "run-a")
        let storeB = try SessionStore(
            storageID: UUID(), runId: "run-b", directory: directory,
            startedAtNs: 1_000, host: .stub)
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

    func testAdapterRunIDNeverControlsDatabasePath() throws {
        let hostile = "../../../../tmp/loupe-escape"
        let store = try makeStore(runId: hostile)
        XCTAssertEqual(store.databaseURL.deletingLastPathComponent(), directory)
        XCTAssertEqual(
            store.databaseURL.lastPathComponent, "\(storageID.uuidString.lowercased()).sqlite")
        XCTAssertFalse(store.databaseURL.path.contains("loupe-escape"))
    }

    func testStoreUsesOwnerOnlyPermissions() throws {
        let store = try makeStore()
        var directoryMetadata = stat()
        XCTAssertEqual(lstat(directory.path, &directoryMetadata), 0)
        XCTAssertEqual(directoryMetadata.st_mode & 0o777, 0o700)
        var databaseMetadata = stat()
        XCTAssertEqual(lstat(store.databaseURL.path, &databaseMetadata), 0)
        XCTAssertEqual(databaseMetadata.st_mode & 0o777, 0o600)
    }

    func testStoreRejectsDatabaseSymlinkBeforeOpeningIt() throws {
        let victim = directory.appendingPathComponent("victim")
        try Data("unchanged".utf8).write(to: victim)
        XCTAssertEqual(chmod(victim.path, 0o644), 0)
        let database = directory.appendingPathComponent(
            "\(storageID.uuidString.lowercased()).sqlite")
        try FileManager.default.createSymbolicLink(at: database, withDestinationURL: victim)

        XCTAssertThrowsError(try makeStore())
        XCTAssertEqual(try String(contentsOf: victim, encoding: .utf8), "unchanged")
        var metadata = stat()
        XCTAssertEqual(lstat(victim.path, &metadata), 0)
        XCTAssertEqual(metadata.st_mode & 0o777, 0o644)
    }

    func testStoreRejectsHardLinkedDatabaseBeforeOpeningIt() throws {
        let victim = directory.appendingPathComponent("hardlink-victim")
        try Data("unchanged".utf8).write(to: victim)
        XCTAssertEqual(chmod(victim.path, 0o600), 0)
        let database = directory.appendingPathComponent(
            "\(storageID.uuidString.lowercased()).sqlite")
        try FileManager.default.linkItem(at: victim, to: database)

        XCTAssertThrowsError(try makeStore())
        XCTAssertEqual(try String(contentsOf: victim, encoding: .utf8), "unchanged")
    }

    func testStoreRejectsOrphanedDatabaseSidecar() throws {
        let sidecar = directory.appendingPathComponent(
            "\(storageID.uuidString.lowercased()).sqlite-wal")
        try Data("untrusted stale wal".utf8).write(to: sidecar)
        XCTAssertEqual(chmod(sidecar.path, 0o600), 0)

        XCTAssertThrowsError(try makeStore())
        XCTAssertEqual(try String(contentsOf: sidecar, encoding: .utf8), "untrusted stale wal")
    }

    func testReplayExportIsOwnerOnlyAndRoundTripsValidatedRows() async throws {
        let store = try makeStore()
        try await store.append(samples: [
            SystemSample(
                system: SystemWideSample(
                    ts: 2_000, thermalState: .fair, memoryUsedBytes: 10,
                    memoryFreeBytes: 20, swapUsedBytes: 0, gpuBusyPercent: 25),
                process: ProcessSample(ts: 2_000, pid: 42, cpuPercent: 50, rssBytes: 30))
        ])
        try await store.append(events: [
            EventEnvelope(
                ts: 1_500, runId: "run-test", requestId: nil,
                payload: .sessionStart(
                    .init(adapter: "test", adapterVersion: "1", runtime: "test", pid: 42)))
        ])

        let replayDirectory = directory.appendingPathComponent("replays")
        let pair = try await store.exportReplayPair(to: replayDirectory)
        XCTAssertTrue(pair.isComplete)
        XCTAssertEqual(try pair.readEvents().count, 1)
        XCTAssertEqual(try pair.readSystemSamples().count, 1)

        for url in [pair.eventsURL, pair.systemURL] {
            var metadata = stat()
            XCTAssertEqual(lstat(url.path, &metadata), 0)
            XCTAssertEqual(metadata.st_mode & 0o777, 0o600)
            XCTAssertEqual(metadata.st_uid, geteuid())
        }
        var directoryMetadata = stat()
        XCTAssertEqual(lstat(replayDirectory.path, &directoryMetadata), 0)
        XCTAssertEqual(directoryMetadata.st_mode & 0o777, 0o700)
    }

    func testReplayExportRejectsSymlinkDirectory() async throws {
        let store = try makeStore()
        let destination = directory.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        let symlink = directory.appendingPathComponent("linked-replays")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: destination)

        do {
            _ = try await store.exportReplayPair(to: symlink)
            XCTFail("Expected a symlink destination to be rejected")
        } catch {
            XCTAssertEqual(error as? StoreError, .unsafeDirectory(symlink.path))
        }
    }
}
