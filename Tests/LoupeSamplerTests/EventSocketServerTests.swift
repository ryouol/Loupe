import Darwin
import Foundation
import XCTest

@testable import LoupeCore
@testable import LoupeSampler

final class EventSocketServerTests: XCTestCase {
    private func socketFixture() throws -> (directory: URL, path: String) {
        // sockaddr_un caps paths at ~104 bytes; keep it short and private.
        let directory = URL(fileURLWithPath: "/tmp/loupe-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        XCTAssertEqual(chmod(directory.path, S_IRWXU), 0)
        return (directory, directory.appendingPathComponent("adapter.sock").path)
    }

    private func connect(to path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: Array(path.utf8))
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(result, 0, "connect failed: errno \(errno)")
        return fd
    }

    private func send(_ text: String, over fd: Int32) {
        _ = Array(text.utf8).withUnsafeBytes { raw in
            write(fd, raw.baseAddress, raw.count)
        }
    }

    func testValidLinesFlowAndMalformedLinesDrop() async throws {
        let fixture = try socketFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let path = fixture.path
        let server = EventSocketServer(socketPath: path)
        let stream = try await server.start()
        defer { Task { await server.stop() } }

        let fd = try connect(to: path)
        defer { close(fd) }
        send(
            #"{"v":1,"ts":10,"runId":"r-s","event":"session_start","payload":{"adapter":"a","adapterVersion":"1","runtime":"mlx","pid":9}}"#
                + "\n" + #"{not json"# + "\n"
                + #"{"v":1,"ts":20,"runId":"r-s","requestId":"q-1","event":"decode_tick","payload":{"outputTokens":1,"kvCacheBytes":2,"activeMemoryBytes":3}}"#
                + "\n",
            over: fd)

        var received: [EventEnvelope] = []
        for await envelope in stream {
            received.append(envelope)
            if received.count == 2 { break }
        }
        XCTAssertEqual(received.map(\.kind), [.sessionStart, .decodeTick])
        XCTAssertEqual(received.map(\.ts), [10, 20])

        // The drop is recorded asynchronously to the valid lines; poll briefly.
        for _ in 0..<50 {
            if await server.drops.total == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let drops = await server.drops
        XCTAssertEqual(drops.total, 1)
        XCTAssertEqual(drops.byReason["malformed_json"], 1)
    }

    func testProtocolV2SequenceGapAndProducerSummaryRemainObservable() async throws {
        let fixture = try socketFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let server = EventSocketServer(socketPath: fixture.path)
        let stream = try await server.start()
        defer { withExtendedLifetime(stream) {} }
        defer { Task { await server.stop() } }

        let descriptor = try connect(to: fixture.path)
        defer { close(descriptor) }
        send(
            #"{"v":2,"seq":1,"ts":10,"runId":"r-v2","event":"session_start","payload":{"adapter":"a","adapterVersion":"1","runtime":"mlx","pid":9}}"#
                + "\n"
                + #"{"v":2,"seq":3,"ts":20,"runId":"r-v2","event":"clock_sync","payload":{"t0":20,"t1":20,"t2":20,"t3":20}}"#
                + "\n"
                + #"{"v":2,"seq":4,"ts":30,"runId":"r-v2","event":"transport_summary","payload":{"attemptedEvents":3,"producerDroppedEvents":1}}"#
                + "\n",
            over: descriptor)

        for _ in 0..<100 {
            if await server.producerReportedDrops == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let losses = await server.acquisitionLosses()
        XCTAssertEqual(losses.exact, 1)
        XCTAssertEqual(losses.lowerBound, 1)
        XCTAssertEqual(losses.breakdown["producer_reported"], 1)
        XCTAssertEqual(losses.breakdown["producer_sequence_gap_lower_bound"], 1)
    }

    func testConsumerBackpressureIsCountedInExactAcquisitionLosses() async throws {
        let fixture = try socketFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let server = EventSocketServer(
            socketPath: fixture.path, maxBufferedEvents: 1)
        let stream = try await server.start()
        defer { withExtendedLifetime(stream) {} }
        defer { Task { await server.stop() } }

        let descriptor = try connect(to: fixture.path)
        defer { close(descriptor) }
        send(
            #"{"v":2,"seq":1,"ts":10,"runId":"r-pressure","event":"session_start","payload":{"adapter":"a","adapterVersion":"1","runtime":"mlx","pid":9}}"#
                + "\n"
                + #"{"v":2,"seq":2,"ts":20,"runId":"r-pressure","event":"clock_sync","payload":{"t0":20,"t1":20,"t2":20,"t3":20}}"#
                + "\n"
                + #"{"v":2,"seq":3,"ts":30,"runId":"r-pressure","event":"transport_summary","payload":{"attemptedEvents":2,"producerDroppedEvents":0}}"#
                + "\n",
            over: descriptor)

        for _ in 0..<100 {
            if await server.producerReportedDrops == 0,
                await server.overflowDrops == 2
            {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let losses = await server.acquisitionLosses()
        XCTAssertEqual(losses.exact, 2)
        XCTAssertEqual(losses.lowerBound, 2)
        XCTAssertEqual(losses.breakdown["event_buffer"], 2)
    }

    func testNonmonotonicSequencePreventsAnExactTransportClaim() async throws {
        let fixture = try socketFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let server = EventSocketServer(socketPath: fixture.path)
        let stream = try await server.start()
        defer { withExtendedLifetime(stream) {} }
        defer { Task { await server.stop() } }

        let descriptor = try connect(to: fixture.path)
        defer { close(descriptor) }
        send(
            #"{"v":2,"seq":1,"ts":10,"runId":"r-order","event":"session_start","payload":{"adapter":"a","adapterVersion":"1","runtime":"mlx","pid":9}}"#
                + "\n"
                + #"{"v":2,"seq":1,"ts":20,"runId":"r-order","event":"clock_sync","payload":{"t0":20,"t1":20,"t2":20,"t3":20}}"#
                + "\n"
                + #"{"v":2,"seq":3,"ts":30,"runId":"r-order","event":"transport_summary","payload":{"attemptedEvents":2,"producerDroppedEvents":0}}"#
                + "\n",
            over: descriptor)

        for _ in 0..<100 {
            if await server.sequenceIntegrityViolations > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let losses = await server.acquisitionLosses()
        XCTAssertNil(losses.exact)
        XCTAssertGreaterThanOrEqual(losses.lowerBound, 1)
        XCTAssertGreaterThan(losses.breakdown["sequence_integrity_violations"] ?? 0, 0)
    }

    func testMultipleClosedProducerWindowsAggregateExactly() async throws {
        let fixture = try socketFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let server = EventSocketServer(socketPath: fixture.path)
        let stream = try await server.start()
        defer { withExtendedLifetime(stream) {} }
        defer { Task { await server.stop() } }

        let descriptor = try connect(to: fixture.path)
        defer { close(descriptor) }
        send(
            #"{"v":2,"seq":1,"ts":10,"runId":"r-windows","event":"session_start","payload":{"adapter":"a","adapterVersion":"1","runtime":"mlx","pid":9}}"#
                + "\n"
                + #"{"v":2,"seq":2,"ts":20,"runId":"r-windows","event":"transport_summary","payload":{"attemptedEvents":1,"producerDroppedEvents":0}}"#
                + "\n"
                + #"{"v":2,"seq":1,"ts":30,"runId":"r-windows","event":"session_start","payload":{"adapter":"a","adapterVersion":"1","runtime":"mlx","pid":9}}"#
                + "\n"
                + #"{"v":2,"seq":3,"ts":40,"runId":"r-windows","event":"transport_summary","payload":{"attemptedEvents":2,"producerDroppedEvents":1}}"#
                + "\n",
            over: descriptor)

        for _ in 0..<100 {
            if await server.producerReportedDrops == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let losses = await server.acquisitionLosses()
        XCTAssertEqual(losses.exact, 1)
        XCTAssertEqual(losses.lowerBound, 1)
    }

    func testPartialWritesReassembleAcrossReads() async throws {
        let fixture = try socketFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let path = fixture.path
        let server = EventSocketServer(socketPath: path)
        let stream = try await server.start()
        defer { Task { await server.stop() } }

        let fd = try connect(to: path)
        defer { close(fd) }
        let line =
            #"{"v":1,"ts":77,"runId":"r-p","event":"model_load_start","payload":{"modelId":"m"}}"#
            + "\n"
        let midpoint = line.index(line.startIndex, offsetBy: 40)
        send(String(line[..<midpoint]), over: fd)
        try await Task.sleep(for: .milliseconds(50))
        send(String(line[midpoint...]), over: fd)

        for await envelope in stream {
            XCTAssertEqual(envelope.kind, .modelLoadStart)
            XCTAssertEqual(envelope.ts, 77)
            break
        }
    }

    func testTruncatedFinalLineAtDisconnectIsCounted() async throws {
        let fixture = try socketFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let server = EventSocketServer(socketPath: fixture.path)
        _ = try await server.start()
        defer { Task { await server.stop() } }

        let descriptor = try connect(to: fixture.path)
        send(#"{"v":2,"seq":1,"ts":10"#, over: descriptor)
        close(descriptor)

        for _ in 0..<100 {
            if await server.drops.total == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let losses = await server.acquisitionLosses()
        XCTAssertEqual(losses.breakdown["socket_parser"], 1)
        XCTAssertGreaterThanOrEqual(losses.lowerBound, 1)
        XCTAssertNil(losses.exact)
    }

    func testUnterminatedFloodIsBoundedAndDropped() async throws {
        let fixture = try socketFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let path = fixture.path
        let server = EventSocketServer(socketPath: path)
        _ = try await server.start()
        defer { Task { await server.stop() } }

        let fd = try connect(to: path)
        defer { close(fd) }
        // 80KB with no newline: must become an oversized drop, not a growing
        // buffer.
        send(String(repeating: "a", count: 80_000), over: fd)

        for _ in 0..<100 {
            if await server.drops.total >= 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let drops = await server.drops
        XCTAssertGreaterThanOrEqual(drops.byReason["oversized_line"] ?? 0, 1)
    }

    func testBindFailureThrowsInsteadOfCrashing() async {
        let server = EventSocketServer(socketPath: "/nonexistent-dir/loupe.sock")
        do {
            _ = try await server.start()
            XCTFail("expected bind failure")
        } catch {
            // Expected: the daemon logs this and degrades to XPC-only.
        }
    }

    func testSocketAndParentPermissionsArePrivate() async throws {
        let fixture = try socketFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let server = EventSocketServer(socketPath: fixture.path)
        _ = try await server.start()
        defer { Task { await server.stop() } }

        var socketMetadata = stat()
        XCTAssertEqual(lstat(fixture.path, &socketMetadata), 0)
        XCTAssertEqual(socketMetadata.st_mode & 0o777, 0o600)
        var directoryMetadata = stat()
        XCTAssertEqual(lstat(fixture.directory.path, &directoryMetadata), 0)
        XCTAssertEqual(directoryMetadata.st_mode & 0o777, 0o700)
    }

    func testRefusesWorldReadableParentDirectory() async {
        let server = EventSocketServer(socketPath: "/tmp/loupe-unsafe.sock")
        do {
            _ = try await server.start()
            XCTFail("world-writable parent must be rejected")
        } catch let error as EventSocketServer.SocketError {
            guard case .unsafeParentDirectory = error else {
                XCTFail("unexpected error: \(error)")
                return
            }
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testSecondServerCannotUnlinkLiveSocket() async throws {
        let fixture = try socketFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let first = EventSocketServer(socketPath: fixture.path)
        _ = try await first.start()
        defer { Task { await first.stop() } }

        let second = EventSocketServer(socketPath: fixture.path)
        do {
            _ = try await second.start()
            XCTFail("a live listener must retain ownership of its socket")
        } catch let error as EventSocketServer.SocketError {
            XCTAssertEqual(error, .socketInUse(fixture.path))
        }

        let descriptor = try connect(to: fixture.path)
        close(descriptor)
    }
}
