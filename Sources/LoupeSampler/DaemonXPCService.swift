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

/// Exported object for one connection. Lives here (not in the daemon
/// binary) so tests can drive real NSXPC in-process.
///
/// Start/stop arrive on XPC's queue in call order, but two fire-and-forget
/// Tasks could reach the broadcaster reordered — so commands flow through
/// one AsyncStream consumed by one pump task, preserving XPC's ordering.
public final class DaemonXPCService: NSObject, LoupeDaemonXPCProtocol, Sendable {
    private enum Command: Sendable {
        case start(any TelemetrySource, XPCReceiverBox)
        case stop
    }

    private let box: XPCReceiverBox?
    private let daemonVersion: String
    private let makeSource: TelemetrySourceFactory
    private let commands: AsyncStream<Command>.Continuation
    private let pump: Task<Void, Never>

    public init(
        remoteReceiver: (any LoupeSampleReceiverXPCProtocol)?,
        daemonVersion: String,
        makeSource: @escaping TelemetrySourceFactory
    ) {
        self.box = remoteReceiver.map(XPCReceiverBox.init)
        self.daemonVersion = daemonVersion
        self.makeSource = makeSource
        let (stream, continuation) = AsyncStream.makeStream(of: Command.self)
        self.commands = continuation
        let broadcaster = SampleBroadcaster()
        self.pump = Task {
            for await command in stream {
                switch command {
                case .start(let source, let box): await broadcaster.start(source: source, box: box)
                case .stop: await broadcaster.stop()
                }
            }
            await broadcaster.stop()
        }
    }

    deinit {
        commands.finish()
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
        commands.yield(.start(source, box))
    }

    public func stopSampleStream() {
        commands.yield(.stop)
    }

    /// Ends streaming and the pump; called when the connection dies.
    public func shutdown() {
        commands.finish()
    }
}

/// Accepts connections for both the mach-service listener (daemon) and
/// anonymous listeners (tests).
public final class DaemonListenerDelegate: NSObject, NSXPCListenerDelegate, Sendable {
    private let daemonVersion: String
    private let makeSource: TelemetrySourceFactory

    /// No default source: which telemetry backs the daemon is a composition
    /// decision that belongs at the composition root, visibly.
    public init(daemonVersion: String, makeSource: @escaping TelemetrySourceFactory) {
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
        let service = DaemonXPCService(
            remoteReceiver: receiver, daemonVersion: daemonVersion, makeSource: makeSource)
        newConnection.exportedObject = service
        // A crashed or force-quit client never sends stopSampleStream; the
        // daemon must notice on its own or it samples forever as root.
        newConnection.interruptionHandler = { service.shutdown() }
        newConnection.invalidationHandler = { service.shutdown() }
        newConnection.resume()
        return true
    }
}
