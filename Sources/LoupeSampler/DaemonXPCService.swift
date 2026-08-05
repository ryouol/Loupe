import Foundation
import LoupeCore

/// XPC proxies are documented thread-safe; the compiler can't see that, so
/// this box states the fact once.
struct XPCReceiverBox: @unchecked Sendable {
    let receiver: any LoupeSampleReceiverXPCProtocol

    func deliver(_ data: Data) {
        receiver.deliver(sampleData: data)
    }
}

/// Streaming state for one connection, isolated from NSXPC callback threads.
actor SampleBroadcaster {
    private var task: Task<Void, Never>?

    func start(source: any TelemetrySource, box: XPCReceiverBox) {
        stop()
        task = Task {
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

/// Exported object for one connection; every call hops into the broadcaster
/// actor, so concurrent XPC callbacks need no locks. Lives here (not in the
/// daemon binary) so tests can drive real NSXPC in-process.
public final class DaemonXPCService: NSObject, LoupeDaemonXPCProtocol, Sendable {
    private let broadcaster = SampleBroadcaster()
    private let box: XPCReceiverBox?
    private let daemonVersion: String
    private let makeSource: TelemetrySourceFactory

    public init(
        remoteReceiver: (any LoupeSampleReceiverXPCProtocol)?,
        daemonVersion: String,
        makeSource: @escaping TelemetrySourceFactory
    ) {
        self.box = remoteReceiver.map(XPCReceiverBox.init)
        self.daemonVersion = daemonVersion
        self.makeSource = makeSource
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
        let source = makeSource(Sampling.clampedCadence(intervalMs: intervalMs))
        Task { await broadcaster.start(source: source, box: box) }
    }

    public func stopSampleStream() {
        Task { await broadcaster.stop() }
    }
}

/// Accepts connections for both the mach-service listener (daemon) and
/// anonymous listeners (tests).
public final class DaemonListenerDelegate: NSObject, NSXPCListenerDelegate, Sendable {
    private let daemonVersion: String
    private let makeSource: TelemetrySourceFactory

    public init(
        daemonVersion: String,
        makeSource: @escaping TelemetrySourceFactory = { cadence in
            UnprivilegedTelemetrySource(targetPID: nil, cadence: cadence)
        }
    ) {
        self.daemonVersion = daemonVersion
        self.makeSource = makeSource
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
            remoteReceiver: receiver, daemonVersion: daemonVersion, makeSource: makeSource)
        newConnection.resume()
        return true
    }
}
