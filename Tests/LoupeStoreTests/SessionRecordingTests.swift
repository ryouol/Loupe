import Darwin
import Foundation
import XCTest

@testable import LoupeCore
@testable import LoupeSampler
@testable import LoupeStore
@testable import LoupeTelemetry

private actor FiniteTelemetrySource: TelemetrySource {
    let pid: Int32?

    init(pid: Int32?) {
        self.pid = pid
    }

    func stream() -> AsyncStream<SystemSample> {
        let pid = pid
        return AsyncStream { continuation in
            for _ in 0..<4 {
                // Use observed timestamps. Fabricating samples milliseconds
                // into the future makes a later PID-correlated source overlap
                // this source even though the recorder drains them in order.
                let timestamp = Timebase.live().nowNanoseconds()
                continuation.yield(
                    SystemSample(
                        system: SystemWideSample(
                            ts: timestamp, thermalState: .nominal,
                            memoryUsedBytes: 1_000, memoryFreeBytes: 2_000,
                            swapUsedBytes: 0),
                        process: pid.map {
                            ProcessSample(
                                ts: timestamp, pid: $0, cpuPercent: 10,
                                rssBytes: 500)
                        }))
            }
            continuation.finish()
        }
    }

    func acquisitionStats() -> TelemetryAcquisitionStats {
        TelemetryAcquisitionStats(complete: true)
    }
}

final class SessionRecordingTests: XCTestCase {
    private func paths() -> LoupeStoragePaths {
        LoupeStoragePaths(
            applicationSupportDirectory: URL(
                fileURLWithPath: "/tmp/loupe-rec-\(UUID().uuidString.prefix(8))"))
    }

    private func connect(to path: String) throws -> Int32 {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.ENOTSOCK) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: Array(path.utf8))
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(
                    descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            close(descriptor)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ECONNREFUSED)
        }
        return descriptor
    }

    private func send(_ envelope: EventEnvelope, to descriptor: Int32) throws {
        var data = try EventLineEncoder().encode(envelope)
        data.append(UInt8(ascii: "\n"))
        let written = data.withUnsafeBytes {
            write(descriptor, $0.baseAddress, $0.count)
        }
        XCTAssertEqual(written, data.count)
    }

    private func waitFor(
        timeoutIterations: Int = 200,
        condition: @escaping @Sendable () async -> Bool
    ) async {
        for _ in 0..<timeoutIterations {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func testRecordStopPersistsHistoryAndPortableEvidence() async throws {
        let paths = paths()
        defer {
            try? FileManager.default.removeItem(at: paths.rootDirectory.deletingLastPathComponent())
        }
        let recorder = SessionRecorder(
            paths: paths, host: .stub,
            makeTelemetry: { FiniteTelemetrySource(pid: $0) })
        let started = try await recorder.start(displayName: "Test session")
        let manifestPath = paths.sessionsDirectory.appendingPathComponent(
            started.storageID.uuidString.lowercased() + ".session.json"
        ).path
        var manifestMetadata = stat()
        XCTAssertEqual(lstat(manifestPath, &manifestMetadata), 0)
        XCTAssertEqual(manifestMetadata.st_mode & 0o777, 0o600)
        let descriptor = try connect(to: paths.adapterSocketURL.path)
        defer { close(descriptor) }
        let pid = ProcessInfo.processInfo.processIdentifier
        let now = Timebase.live().nowNanoseconds()
        let applicationEvents: [EventEnvelope] = [
            EventEnvelope(
                version: EventProtocol.version, sequence: 1,
                ts: now, runId: started.runID, requestId: nil,
                payload: .sessionStart(
                    .init(adapter: "test", adapterVersion: "1", runtime: "test", pid: pid))),
            EventEnvelope(
                version: EventProtocol.version, sequence: 2,
                ts: now + 1, runId: started.runID, requestId: nil,
                payload: .clockSync(.init(t0: now, t1: now, t2: now, t3: now))),
            EventEnvelope(
                version: EventProtocol.version, sequence: 3,
                ts: now + 2, runId: started.runID, requestId: "q-1",
                payload: .requestStart(.init(promptTokens: 4))),
            EventEnvelope(
                version: EventProtocol.version, sequence: 4,
                ts: now + 3, runId: started.runID, requestId: "q-1",
                payload: .prefillEnd(.init(promptTokens: 4))),
            EventEnvelope(
                version: EventProtocol.version, sequence: 5,
                ts: now + 4, runId: started.runID, requestId: "q-1",
                payload: .decodeTick(
                    .init(
                        outputTokens: 1, kvCacheBytes: nil, activeMemoryBytes: 1,
                        allocatorMemoryGrowthBytes: 1,
                        memoryProvenance: .allocatorDeltaProxy))),
            EventEnvelope(
                version: EventProtocol.version, sequence: 6,
                ts: now + 5, runId: started.runID, requestId: "q-1",
                payload: .requestEnd(.init(outputTokens: 2, finishReason: "stop"))),
            EventEnvelope(
                version: EventProtocol.version, sequence: 7,
                ts: now + 6, runId: started.runID, requestId: nil,
                payload: .transportSummary(
                    .init(attemptedEvents: 6, producerDroppedEvents: 0))),
        ]
        for event in applicationEvents { try send(event, to: descriptor) }

        await waitFor { await recorder.currentSession()?.eventCount == applicationEvents.count }
        let stopped = try await recorder.stop()
        XCTAssertEqual(stopped.state, .stopped)
        XCTAssertEqual(stopped.eventCount, applicationEvents.count)
        XCTAssertGreaterThan(stopped.sampleCount, 0)
        XCTAssertTrue(stopped.isReplayAvailable)
        XCTAssertEqual(stopped.acquisitionMetadata?.eventLosses.exact, 0)
        XCTAssertEqual(stopped.acquisitionMetadata?.telemetryLosses.exact, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stopped.filePair.metadataURL.path))

        let library = SessionLibrary(paths: paths)
        let history = try await library.sessions()
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history.first?.storageID, stopped.storageID)
        XCTAssertEqual(history.first?.state, .stopped)
        XCTAssertEqual(history.first?.acquisitionMetadata, stopped.acquisitionMetadata)

        // A fresh store instance models an app relaunch: acquisition
        // integrity must survive independently of the in-memory recorder.
        let reopenedStore = try SessionStore(
            storageID: stopped.storageID, runId: stopped.runID,
            directory: paths.sessionsDirectory, startedAtNs: now, host: .stub)
        let reopenedAcquisition = try await reopenedStore.acquisitionMetadata()
        XCTAssertEqual(reopenedAcquisition, stopped.acquisitionMetadata)

        let decoded = EventLineDecoder().decodeLines(
            try Data(contentsOf: stopped.filePair.eventsURL))
        XCTAssertEqual(decoded.envelopes.count, applicationEvents.count)
        XCTAssertEqual(decoded.drops.total, 0)
        let portableSamples = try Data(contentsOf: stopped.filePair.systemURL)
            .split(separator: UInt8(ascii: "\n"))
            .compactMap { SystemSampleWireDecoder.decode(Data($0)) }
        XCTAssertEqual(
            portableSamples.compactMap(\.acquisitionSequence),
            (1...portableSamples.count).map(UInt64.init))

        try await library.delete(stopped)
        let sessionsAfterDelete = try await library.sessions()
        XCTAssertTrue(sessionsAfterDelete.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stopped.filePair.eventsURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stopped.filePair.systemURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stopped.filePair.metadataURL.path))
    }

    func testWrongRunIDTransitionsToDeniedWithoutPersistence() async throws {
        let paths = paths()
        defer {
            try? FileManager.default.removeItem(at: paths.rootDirectory.deletingLastPathComponent())
        }
        let recorder = SessionRecorder(
            paths: paths, host: .stub,
            makeTelemetry: { FiniteTelemetrySource(pid: $0) })
        _ = try await recorder.start()
        let descriptor = try connect(to: paths.adapterSocketURL.path)
        defer { close(descriptor) }
        try send(
            EventEnvelope(
                ts: Timebase.live().nowNanoseconds(), runId: "wrong", requestId: nil,
                payload: .sessionStart(
                    .init(
                        adapter: "test", adapterVersion: "1", runtime: "test",
                        pid: ProcessInfo.processInfo.processIdentifier))),
            to: descriptor)

        await waitFor { await recorder.currentSession()?.state == .denied }
        let denied = await recorder.currentSession()
        XCTAssertEqual(denied?.state, .denied)
        XCTAssertEqual(denied?.eventCount, 0)
        _ = try await recorder.stop()
    }

    func testMalformedSocketInputSurfacesDegradedState() async throws {
        let paths = paths()
        defer {
            try? FileManager.default.removeItem(at: paths.rootDirectory.deletingLastPathComponent())
        }
        let recorder = SessionRecorder(
            paths: paths, host: .stub,
            makeTelemetry: { FiniteTelemetrySource(pid: $0) })
        _ = try await recorder.start()
        let descriptor = try connect(to: paths.adapterSocketURL.path)
        defer { close(descriptor) }
        let malformed = Data("{not-json}\n".utf8)
        _ = malformed.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }

        await waitFor { await recorder.currentSession()?.state == .degraded }
        let degraded = await recorder.currentSession()
        XCTAssertEqual(degraded?.state, .degraded)
        let stopped = try await recorder.stop()
        XCTAssertNil(stopped.acquisitionMetadata?.eventLosses.exact)
        XCTAssertGreaterThanOrEqual(
            stopped.acquisitionMetadata?.eventLosses.lowerBound ?? 0, 1)
    }

    func testReconnectAcceptsFreshSessionStartAcrossStatusRace() async throws {
        let paths = paths()
        defer {
            try? FileManager.default.removeItem(at: paths.rootDirectory.deletingLastPathComponent())
        }
        let recorder = SessionRecorder(
            paths: paths, host: .stub,
            makeTelemetry: { FiniteTelemetrySource(pid: $0) })
        let started = try await recorder.start()
        let pid = ProcessInfo.processInfo.processIdentifier
        let first = try connect(to: paths.adapterSocketURL.path)
        try send(
            EventEnvelope(
                ts: 100, runId: started.runID, requestId: nil,
                payload: .sessionStart(
                    .init(adapter: "test", adapterVersion: "1", runtime: "test", pid: pid))),
            to: first)
        await waitFor { await recorder.currentSession()?.state == .recording }
        close(first)
        await waitFor { await recorder.currentSession()?.state == .adapterDisconnected }

        let second = try connect(to: paths.adapterSocketURL.path)
        defer { close(second) }
        try send(
            EventEnvelope(
                ts: 200, runId: started.runID, requestId: nil,
                payload: .sessionStart(
                    .init(adapter: "test", adapterVersion: "1", runtime: "test", pid: pid))),
            to: second)

        await waitFor {
            let session = await recorder.currentSession()
            return session?.state == .recording && session?.eventCount == 2
        }
        let reconnected = await recorder.currentSession()
        XCTAssertEqual(reconnected?.state, .recording)
        XCTAssertEqual(reconnected?.eventCount, 2)
        _ = try await recorder.stop()
    }

    func testCurrentProtocolCleanReconnectPreservesExactLossAndReplay() async throws {
        let paths = paths()
        defer {
            try? FileManager.default.removeItem(at: paths.rootDirectory.deletingLastPathComponent())
        }
        let recorder = SessionRecorder(
            paths: paths, host: .stub,
            makeTelemetry: { FiniteTelemetrySource(pid: $0) })
        let started = try await recorder.start()
        let pid = ProcessInfo.processInfo.processIdentifier

        for window in 0..<2 {
            let descriptor = try connect(to: paths.adapterSocketURL.path)
            let timestamp = UInt64(100 + window * 10)
            let requestID = "q-window-\(window)"
            let events = [
                EventEnvelope(
                    version: EventProtocol.version, sequence: 1,
                    ts: timestamp, runId: started.runID, requestId: nil,
                    payload: .sessionStart(
                        .init(
                            adapter: "test", adapterVersion: "2", runtime: "test",
                            pid: pid))),
                EventEnvelope(
                    version: EventProtocol.version, sequence: 2,
                    ts: timestamp + 1, runId: started.runID, requestId: requestID,
                    payload: .requestStart(.init(promptTokens: 1))),
                EventEnvelope(
                    version: EventProtocol.version, sequence: 3,
                    ts: timestamp + 2, runId: started.runID, requestId: requestID,
                    payload: .prefillEnd(.init(promptTokens: 1))),
                EventEnvelope(
                    version: EventProtocol.version, sequence: 4,
                    ts: timestamp + 3, runId: started.runID, requestId: requestID,
                    payload: .decodeTick(
                        .init(
                            outputTokens: 1, kvCacheBytes: nil, activeMemoryBytes: 1,
                            allocatorMemoryGrowthBytes: 1,
                            memoryProvenance: .allocatorDeltaProxy))),
                EventEnvelope(
                    version: EventProtocol.version, sequence: 5,
                    ts: timestamp + 4, runId: started.runID, requestId: requestID,
                    payload: .requestEnd(
                        .init(
                            outputTokens: 1, finishReason: "stop",
                            decodeDurationNs: 1))),
                EventEnvelope(
                    version: EventProtocol.version, sequence: 6,
                    ts: timestamp + 5, runId: started.runID, requestId: nil,
                    payload: .transportSummary(
                        .init(attemptedEvents: 5, producerDroppedEvents: 0))),
            ]
            for event in events { try send(event, to: descriptor) }

            await waitFor {
                await recorder.currentSession()?.eventCount == (window + 1) * events.count
            }
            close(descriptor)
            if window == 0 {
                await waitFor {
                    await recorder.currentSession()?.state == .adapterDisconnected
                }
            }
        }

        let stopped = try await recorder.stop()
        XCTAssertEqual(stopped.eventCount, 12)
        XCTAssertEqual(stopped.acquisitionMetadata?.eventLosses.exact, 0)

        let replay = ReplayEventSource(fileURL: stopped.filePair.eventsURL)
        var replayed: [EventEnvelope] = []
        for await envelope in await replay.stream() { replayed.append(envelope) }
        XCTAssertEqual(replayed.count, 12)
        XCTAssertEqual(replayed.filter { $0.kind == .sessionStart }.count, 2)
        XCTAssertEqual(replayed.filter { $0.kind == .transportSummary }.count, 2)
        XCTAssertEqual(SessionMetrics.perRequest(events: replayed).count, 2)
        let replayDrops = await replay.drops.total
        let replayFailure = await replay.loadFailure
        XCTAssertEqual(replayDrops, 0)
        XCTAssertNil(replayFailure)
    }

    func testReconnectCanContinueAnActiveRequest() async throws {
        let paths = paths()
        defer {
            try? FileManager.default.removeItem(at: paths.rootDirectory.deletingLastPathComponent())
        }
        let recorder = SessionRecorder(
            paths: paths, host: .stub,
            makeTelemetry: { FiniteTelemetrySource(pid: $0) })
        let started = try await recorder.start()
        let pid = ProcessInfo.processInfo.processIdentifier
        let first = try connect(to: paths.adapterSocketURL.path)
        for event in [
            EventEnvelope(
                ts: 100, runId: started.runID, requestId: nil,
                payload: .sessionStart(
                    .init(adapter: "test", adapterVersion: "1", runtime: "test", pid: pid))),
            EventEnvelope(
                ts: 101, runId: started.runID, requestId: "q-1",
                payload: .requestStart(.init(promptTokens: 4))),
            EventEnvelope(
                ts: 102, runId: started.runID, requestId: "q-1",
                payload: .prefillEnd(.init(promptTokens: 4))),
        ] {
            try send(event, to: first)
        }
        await waitFor { await recorder.currentSession()?.eventCount == 3 }
        close(first)
        await waitFor { await recorder.currentSession()?.state == .adapterDisconnected }

        let second = try connect(to: paths.adapterSocketURL.path)
        defer { close(second) }
        try send(
            EventEnvelope(
                ts: 103, runId: started.runID, requestId: "q-1",
                payload: .decodeTick(
                    .init(outputTokens: 1, kvCacheBytes: 2, activeMemoryBytes: 3))),
            to: second)
        try send(
            EventEnvelope(
                ts: 104, runId: started.runID, requestId: "q-1",
                payload: .requestEnd(.init(outputTokens: 1, finishReason: "stop"))),
            to: second)

        await waitFor {
            let session = await recorder.currentSession()
            return session?.state == .recording && session?.eventCount == 5
        }
        _ = try await recorder.stop()
    }

    func testReconnectRejectsTimestampRollback() async throws {
        let paths = paths()
        defer {
            try? FileManager.default.removeItem(at: paths.rootDirectory.deletingLastPathComponent())
        }
        let recorder = SessionRecorder(
            paths: paths, host: .stub,
            makeTelemetry: { FiniteTelemetrySource(pid: $0) })
        let started = try await recorder.start()
        let pid = ProcessInfo.processInfo.processIdentifier
        let first = try connect(to: paths.adapterSocketURL.path)
        try send(
            EventEnvelope(
                ts: 200, runId: started.runID, requestId: nil,
                payload: .sessionStart(
                    .init(adapter: "test", adapterVersion: "1", runtime: "test", pid: pid))),
            to: first)
        await waitFor { await recorder.currentSession()?.state == .recording }
        close(first)
        await waitFor { await recorder.currentSession()?.state == .adapterDisconnected }

        let second = try connect(to: paths.adapterSocketURL.path)
        defer { close(second) }
        try send(
            EventEnvelope(
                ts: 100, runId: started.runID, requestId: nil,
                payload: .sessionStart(
                    .init(adapter: "test", adapterVersion: "1", runtime: "test", pid: pid))),
            to: second)

        await waitFor { await recorder.currentSession()?.state == .denied }
        let rejected = await recorder.currentSession()
        XCTAssertEqual(rejected?.state, .denied)
        XCTAssertEqual(rejected?.eventCount, 1)
        _ = try await recorder.stop()
    }

    func testProtocolFailureRequiresFreshSessionStart() async throws {
        let paths = paths()
        defer {
            try? FileManager.default.removeItem(at: paths.rootDirectory.deletingLastPathComponent())
        }
        let recorder = SessionRecorder(
            paths: paths, host: .stub,
            makeTelemetry: { FiniteTelemetrySource(pid: $0) })
        let started = try await recorder.start()
        let descriptor = try connect(to: paths.adapterSocketURL.path)
        defer { close(descriptor) }
        let pid = ProcessInfo.processInfo.processIdentifier
        try send(
            EventEnvelope(
                ts: 100, runId: started.runID, requestId: nil,
                payload: .sessionStart(
                    .init(adapter: "test", adapterVersion: "1", runtime: "test", pid: pid))),
            to: descriptor)
        try send(
            EventEnvelope(
                ts: 101, runId: started.runID, requestId: "q-missing",
                payload: .requestEnd(.init(outputTokens: 1, finishReason: "stop"))),
            to: descriptor)
        try send(
            EventEnvelope(
                ts: 102, runId: started.runID, requestId: "q-late",
                payload: .requestStart(.init(promptTokens: 1))),
            to: descriptor)

        await waitFor { await recorder.currentSession()?.state == .denied }
        let deniedCount = await recorder.currentSession()?.eventCount
        XCTAssertEqual(deniedCount, 1)

        try send(
            EventEnvelope(
                ts: 103, runId: started.runID, requestId: nil,
                payload: .sessionStart(
                    .init(adapter: "test", adapterVersion: "1", runtime: "test", pid: pid))),
            to: descriptor)
        await waitFor {
            let session = await recorder.currentSession()
            return session?.state == .recording && session?.eventCount == 2
        }
        let stopped = try await recorder.stop()
        XCTAssertNil(stopped.acquisitionMetadata?.eventLosses.exact)
        XCTAssertGreaterThanOrEqual(
            stopped.acquisitionMetadata?.eventLosses.lowerBound ?? 0, 2)
        XCTAssertEqual(
            stopped.acquisitionMetadata?.eventLosses.breakdown["recording_validation"], 2)
    }

    func testLibrarySkipsUnsupportedManifestSchema() async throws {
        let paths = paths()
        defer {
            try? FileManager.default.removeItem(at: paths.rootDirectory.deletingLastPathComponent())
        }
        let recorder = SessionRecorder(
            paths: paths, host: .stub,
            makeTelemetry: { FiniteTelemetrySource(pid: $0) })
        _ = try await recorder.start()
        let stopped = try await recorder.stop()
        let manifestURL = paths.sessionsDirectory.appendingPathComponent(
            stopped.storageID.uuidString.lowercased() + ".session.json")
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL))
                as? [String: Any])
        object["schemaVersion"] = 99
        try JSONSerialization.data(withJSONObject: object).write(
            to: manifestURL, options: .atomic)
        XCTAssertEqual(chmod(manifestURL.path, 0o600), 0)

        let sessions = try await SessionLibrary(paths: paths).sessions()
        XCTAssertTrue(sessions.isEmpty)
    }

    func testLegacyManifestRelaunchReportsAcquisitionAsUnknown() async throws {
        let paths = paths()
        defer {
            try? FileManager.default.removeItem(at: paths.rootDirectory.deletingLastPathComponent())
        }
        let recorder = SessionRecorder(
            paths: paths, host: .stub,
            makeTelemetry: { FiniteTelemetrySource(pid: $0) })
        _ = try await recorder.start()
        let stopped = try await recorder.stop()
        let manifestURL = paths.sessionsDirectory.appendingPathComponent(
            stopped.storageID.uuidString.lowercased() + ".session.json")
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL))
                as? [String: Any])
        object["schemaVersion"] = 1
        object.removeValue(forKey: "acquisitionMetadata")
        try JSONSerialization.data(withJSONObject: object).write(
            to: manifestURL, options: .atomic)
        XCTAssertEqual(chmod(manifestURL.path, 0o600), 0)
        try FileManager.default.removeItem(at: stopped.filePair.metadataURL)

        let relaunched = try await SessionLibrary(paths: paths).sessions()
        XCTAssertEqual(relaunched.count, 1)
        XCTAssertNil(relaunched.first?.acquisitionMetadata)
        XCTAssertTrue(relaunched.first?.isReplayAvailable == true)
    }

    func testLibrarySkipsManifestWithUnknownFields() async throws {
        let paths = paths()
        defer {
            try? FileManager.default.removeItem(at: paths.rootDirectory.deletingLastPathComponent())
        }
        let recorder = SessionRecorder(
            paths: paths, host: .stub,
            makeTelemetry: { FiniteTelemetrySource(pid: $0) })
        _ = try await recorder.start()
        let stopped = try await recorder.stop()
        let manifestURL = paths.sessionsDirectory.appendingPathComponent(
            stopped.storageID.uuidString.lowercased() + ".session.json")
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL))
                as? [String: Any])
        object["hiddenMetadata"] = "must not be silently ignored"
        try JSONSerialization.data(withJSONObject: object).write(
            to: manifestURL, options: .atomic)
        XCTAssertEqual(chmod(manifestURL.path, 0o600), 0)

        let sessions = try await SessionLibrary(paths: paths).sessions()
        XCTAssertTrue(sessions.isEmpty)
    }

    func testLibraryValidatesWholeDeletionSetBeforeRemovingAnything() async throws {
        let paths = paths()
        let outside = URL(fileURLWithPath: "/tmp/loupe-delete-target-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: paths.rootDirectory.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: outside)
        }
        let recorder = SessionRecorder(
            paths: paths, host: .stub,
            makeTelemetry: { FiniteTelemetrySource(pid: $0) })
        _ = try await recorder.start()
        let stopped = try await recorder.stop()
        try Data("keep".utf8).write(to: outside)
        let substitutedSidecar = URL(fileURLWithPath: stopped.basePath + ".sqlite-wal")
        try? FileManager.default.removeItem(at: substitutedSidecar)
        try FileManager.default.createSymbolicLink(
            at: substitutedSidecar, withDestinationURL: outside)

        do {
            try await SessionLibrary(paths: paths).delete(stopped)
            XCTFail("expected substituted sidecar to fail closed")
        } catch let error as SessionRecordingError {
            guard case .unsafeStorage = error else {
                XCTFail("unexpected deletion error: \(error)")
                return
            }
        } catch {
            XCTFail("unexpected deletion error: \(error)")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: stopped.basePath + ".sqlite"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: stopped.basePath + ".session.json"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: stopped.filePair.eventsURL.path))
        XCTAssertEqual(try Data(contentsOf: outside), Data("keep".utf8))
    }

    func testDisplayNameIsBoundedByEncodedSize() async throws {
        let paths = paths()
        defer {
            try? FileManager.default.removeItem(at: paths.rootDirectory.deletingLastPathComponent())
        }
        let recorder = SessionRecorder(
            paths: paths, host: .stub,
            makeTelemetry: { FiniteTelemetrySource(pid: $0) })
        let hostile = "a" + String(repeating: "\u{0301}", count: 10_000)
        let started = try await recorder.start(displayName: hostile)
        XCTAssertLessThanOrEqual(started.displayName.utf8.count, 512)
        _ = try await recorder.stop()
    }

    func testStoragePreparationRejectsSymlinkWithoutChangingTargetMode() throws {
        let support = URL(fileURLWithPath: "/tmp/loupe-paths-\(UUID().uuidString.prefix(8))")
        let target = URL(fileURLWithPath: "/tmp/loupe-target-\(UUID().uuidString.prefix(8))")
        defer {
            try? FileManager.default.removeItem(at: support)
            try? FileManager.default.removeItem(at: target)
        }
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        XCTAssertEqual(chmod(target.path, 0o755), 0)
        try FileManager.default.createSymbolicLink(
            at: support.appendingPathComponent("Loupe"), withDestinationURL: target)

        XCTAssertThrowsError(
            try LoupeStoragePaths(applicationSupportDirectory: support).prepare())
        var metadata = stat()
        XCTAssertEqual(lstat(target.path, &metadata), 0)
        XCTAssertEqual(metadata.st_mode & 0o777, 0o755)
    }
}
