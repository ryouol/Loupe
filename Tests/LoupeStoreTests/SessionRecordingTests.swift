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
        let start = Timebase.live().nowNanoseconds()
        return AsyncStream { continuation in
            for index in 0..<4 {
                let timestamp = start + UInt64(index) * 1_000_000
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
        let events: [EventEnvelope] = [
            EventEnvelope(
                ts: now, runId: started.runID, requestId: nil,
                payload: .sessionStart(
                    .init(adapter: "test", adapterVersion: "1", runtime: "test", pid: pid))),
            EventEnvelope(
                ts: now + 1, runId: started.runID, requestId: nil,
                payload: .clockSync(.init(t0: now, t1: now, t2: now, t3: now))),
            EventEnvelope(
                ts: now + 2, runId: started.runID, requestId: "q-1",
                payload: .requestStart(.init(promptTokens: 4))),
            EventEnvelope(
                ts: now + 3, runId: started.runID, requestId: "q-1",
                payload: .prefillEnd(.init(promptTokens: 4))),
            EventEnvelope(
                ts: now + 4, runId: started.runID, requestId: "q-1",
                payload: .requestEnd(.init(outputTokens: 2, finishReason: "stop"))),
        ]
        for event in events { try send(event, to: descriptor) }

        await waitFor { await recorder.currentSession()?.eventCount == events.count }
        let stopped = try await recorder.stop()
        XCTAssertEqual(stopped.state, .stopped)
        XCTAssertEqual(stopped.eventCount, events.count)
        XCTAssertGreaterThan(stopped.sampleCount, 0)
        XCTAssertTrue(stopped.isReplayAvailable)

        let library = SessionLibrary(paths: paths)
        let history = try await library.sessions()
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history.first?.storageID, stopped.storageID)
        XCTAssertEqual(history.first?.state, .stopped)

        let decoded = EventLineDecoder().decodeLines(
            try Data(contentsOf: stopped.filePair.eventsURL))
        XCTAssertEqual(decoded.envelopes.count, events.count)
        XCTAssertEqual(decoded.drops.total, 0)

        try await library.delete(stopped)
        let sessionsAfterDelete = try await library.sessions()
        XCTAssertTrue(sessionsAfterDelete.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stopped.filePair.eventsURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stopped.filePair.systemURL.path))
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
        _ = try await recorder.stop()
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
        _ = try await recorder.stop()
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
