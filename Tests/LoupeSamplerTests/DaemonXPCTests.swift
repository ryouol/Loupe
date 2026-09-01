import Foundation
import XCTest

@testable import LoupeCore
@testable import LoupeSampler
@testable import LoupeTelemetry

/// Drives the real NSXPC machinery in-process through an anonymous listener:
/// no mach service registration, no SMAppService, no root. What this cannot
/// cover — actual launchd registration and reboot survival — is scripted in
/// docs/daemon-validation.md for a signed run.
final class DaemonXPCTests: XCTestCase {
    private func makeConnectedClient() -> (DaemonXPCClient, NSXPCListener, DaemonListenerDelegate) {
        let listener = NSXPCListener.anonymous()
        // Composition is explicit now; include the IOReport reader like the
        // daemon's composition root does, so on real hardware this test
        // still covers GPU data surviving the XPC round trip.
        let delegate = DaemonListenerDelegate(
            daemonVersion: "test-0.0.1", peerValidator: .currentProcessForTesting
        ) { cadence in
            LiveTelemetrySource(
                targetPID: nil, cadence: cadence,
                makePowerReader: { IOReportPowerReader() })
        }
        listener.delegate = delegate
        listener.resume()
        let client = DaemonXPCClient(endpoint: .anonymous(listener.endpoint))
        return (client, listener, delegate)
    }

    func testListenerRejectsPeerWhenPolicyDenies() {
        let listener = NSXPCListener.anonymous()
        let delegate = DaemonListenerDelegate(
            daemonVersion: "test", peerValidator: DaemonPeerValidator { _ in false }
        ) { cadence in
            LiveTelemetrySource(targetPID: nil, cadence: cadence)
        }
        listener.delegate = delegate
        listener.resume()
        defer {
            listener.invalidate()
            _ = delegate
        }

        let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connection.remoteObjectInterface = NSXPCInterface(with: LoupeDaemonXPCProtocol.self)
        connection.resume()
        defer { connection.invalidate() }

        let rejected = expectation(description: "connection rejected")
        connection.invalidationHandler = { rejected.fulfill() }
        (connection.remoteObjectProxy as? LoupeDaemonXPCProtocol)?.handshake(
            clientProtocolVersion: EventProtocol.version
        ) { _ in
            XCTFail("denied peer must not receive a handshake")
        }
        wait(for: [rejected], timeout: 2)
    }

    func testHandshakeRoundTrip() async {
        let (client, listener, delegate) = makeConnectedClient()
        defer {
            client.stopAndInvalidate()
            listener.invalidate()
            _ = delegate
        }
        _ = client.activate()

        let handshake = await client.handshake()
        XCTAssertEqual(handshake?.daemonVersion, "test-0.0.1")
        XCTAssertEqual(handshake?.protocolVersion, EventProtocol.version)
        XCTAssertGreaterThan(handshake?.pid ?? 0, 0)
    }

    func testSampleStreamDeliversRealSamplesOverXPC() async {
        let (client, listener, delegate) = makeConnectedClient()
        defer {
            listener.invalidate()
            _ = delegate
        }
        let stream = client.activate()
        let handshake = await client.handshake()
        XCTAssertNotNil(handshake)
        client.startStream(intervalMs: 20)

        var received: [SystemSample] = []
        for await sample in stream {
            received.append(sample)
            if received.count == 3 { break }
        }
        client.stopAndInvalidate()

        XCTAssertEqual(received.count, 3)
        let timestamps = received.map(\.system.ts)
        XCTAssertEqual(timestamps, timestamps.sorted())
        for sample in received {
            XCTAssertGreaterThan(sample.system.memoryUsedBytes, 0)
            // GPU fields flow when IOReport resolves in this context and stay
            // nil when it doesn't — both are correct; zeros never are.
            if let busy = sample.system.gpuBusyPercent {
                XCTAssertGreaterThanOrEqual(busy, 0)
                XCTAssertLessThanOrEqual(busy, 100)
            }
            XCTAssertNil(sample.process, "the daemon streams system-wide samples only")
        }
    }

    func testInvalidatedConnectionFinishesStreamInsteadOfHanging() async {
        let (client, listener, delegate) = makeConnectedClient()
        defer { _ = delegate }
        let stream = client.activate()
        let handshake = await client.handshake()
        XCTAssertNotNil(handshake)
        client.startStream(intervalMs: 20)

        var count = 0
        for await _ in stream {
            count += 1
            if count == 1 {
                // Simulate the daemon dying mid-stream.
                listener.invalidate()
                client.stopAndInvalidate()
            }
        }
        // Reaching here at all is the assertion: the for-await terminated.
        XCTAssertGreaterThanOrEqual(count, 1)
    }
}
