import Foundation
import LoupeCore

/// Server half of the app ↔ daemon XPC boundary. Lives in LoupeSampler, not
/// the loupedaemon executable, so tests can drive the real NSXPC machinery
/// in-process through an anonymous listener — the daemon binary stays thin
/// wiring, exactly as the layout doc demands.
///
/// XPC proxy objects are documented thread-safe but the compiler cannot see
/// that; this box states the fact once instead of scattering unsafe marks.
struct XPCReceiverBox: @unchecked Sendable {
    let receiver: any LoupeSampleReceiverXPCProtocol

    func deliver(_ data: Data) {
        receiver.deliver(sampleData: data)
    }
}

/// Owns the streaming task for one connection; all mutable state is actor-
/// isolated so the NSXPC callback threads never touch it directly.
actor SampleBroadcaster {
    private var task: Task<Void, Never>?

    func start(intervalMs: Int, box: XPCReceiverBox) {
        stop()
        let cadence = Duration.milliseconds(max(10, min(intervalMs, 10_000)))
        task = Task {
            let source = UnprivilegedTelemetrySource(targetPID: nil, cadence: cadence)
            let encoder = JSONEncoder()
            for await sample in await source.stream() {
                if Task.isCancelled { break }
                if let data = try? encoder.encode(sample) {
                    box.deliver(data)
                }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}

/// Exported object for one accepted connection. Stateless by design: every
/// call hops into the broadcaster actor, so concurrent XPC callbacks are
/// safe without locks.
public final class DaemonXPCService: NSObject, LoupeDaemonXPCProtocol, Sendable {
    private let broadcaster = SampleBroadcaster()
    private let box: XPCReceiverBox?
    private let daemonVersion: String

    public init(remoteReceiver: (any LoupeSampleReceiverXPCProtocol)?, daemonVersion: String) {
        self.box = remoteReceiver.map(XPCReceiverBox.init)
        self.daemonVersion = daemonVersion
    }

    public func handshake(reply: @escaping @Sendable (Data) -> Void) {
        let handshake = DaemonHandshake(
            daemonVersion: daemonVersion,
            protocolVersion: EventProtocol.version,
            pid: ProcessInfo.processInfo.processIdentifier)
        reply((try? JSONEncoder().encode(handshake)) ?? Data())
    }

    public func startSampleStream(intervalMs: Int) {
        guard let box else { return }
        Task { await broadcaster.start(intervalMs: intervalMs, box: box) }
    }

    public func stopSampleStream() {
        Task { await broadcaster.stop() }
    }
}

/// Accepts connections and wires the two interfaces. Used by the daemon
/// against a mach service listener and by tests against an anonymous one.
public final class DaemonListenerDelegate: NSObject, NSXPCListenerDelegate, Sendable {
    private let daemonVersion: String

    public init(daemonVersion: String) {
        self.daemonVersion = daemonVersion
    }

    public func listener(
        _ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        // TODO(M1): require a code-signing entitlement match on the peer
        // before accepting — a root daemon must not trust arbitrary callers.
        // Needs the Team ID, so it lands with real signing.
        newConnection.exportedInterface = NSXPCInterface(with: LoupeDaemonXPCProtocol.self)
        newConnection.remoteObjectInterface = NSXPCInterface(
            with: LoupeSampleReceiverXPCProtocol.self)
        let receiver = newConnection.remoteObjectProxy as? LoupeSampleReceiverXPCProtocol
        newConnection.exportedObject = DaemonXPCService(
            remoteReceiver: receiver, daemonVersion: daemonVersion)
        newConnection.resume()
        return true
    }
}
