import Darwin
import Foundation
import LoupeCore
import Security

/// XPC proxies are documented thread-safe; the compiler can't see that, so
/// this box states the fact once.
struct XPCReceiverBox: @unchecked Sendable {
    let receiver: any LoupeSampleReceiverXPCProtocol

    func deliver(_ data: Data) {
        receiver.deliver(sampleData: data)
    }

    func deliverSummary(_ data: Data) {
        receiver.deliver(summaryData: data)
    }
}

private final class ConnectionLease: @unchecked Sendable {
    private let lock = NSLock()
    private var releaseAction: (@Sendable () -> Void)?

    init(release: @escaping @Sendable () -> Void) {
        self.releaseAction = release
    }

    func release() {
        let action = lock.withLock { () -> (@Sendable () -> Void)? in
            defer { releaseAction = nil }
            return releaseAction
        }
        action?()
    }
}

private final class ConnectionLimiter: @unchecked Sendable {
    private let lock = NSLock()
    private let maximum: Int
    private var active = 0

    init(maximum: Int) {
        self.maximum = max(1, min(maximum, 16))
    }

    func acquire() -> ConnectionLease? {
        let admitted = lock.withLock { () -> Bool in
            guard active < maximum else { return false }
            active += 1
            return true
        }
        guard admitted else { return nil }
        return ConnectionLease { [weak self] in
            self?.lock.withLock { self?.active -= 1 }
        }
    }
}

/// Streaming state for one connection, isolated from NSXPC callback threads.
actor SampleBroadcaster {
    private var task: Task<Data?, Never>?

    func start(source: any TelemetrySource, box: XPCReceiverBox) async {
        _ = await stop()
        task = Task {
            let encoder = JSONEncoder()
            var encodingDrops = 0
            for await sample in await source.stream() {
                // Preserve any row already accepted from the source. The
                // next iterator step observes cancellation; dropping here
                // would create an unobservable transport loss.
                if let data = try? encoder.encode(sample) {
                    box.deliver(data)
                } else if encodingDrops < Int.max {
                    encodingDrops += 1
                }
            }
            let sourceStats = await source.acquisitionStats()
            let stats = TelemetryAcquisitionStats(
                droppedSamples:
                    sourceStats.droppedSamples > Int.max - encodingDrops
                    ? Int.max : sourceStats.droppedSamples + encodingDrops,
                sequenceGapLowerBound: sourceStats.sequenceGapLowerBound,
                malformedSamples: sourceStats.malformedSamples,
                complete: sourceStats.complete,
                sourceWasActive: sourceStats.sourceWasActive)
            if let data = try? encoder.encode(stats) {
                box.deliverSummary(data)
                return data
            }
            return nil
        }
    }

    func stop() async -> Data? {
        let active = task
        task = nil
        active?.cancel()
        return await active?.value
    }
}

/// Exported object for one connection. Lives here (not in the daemon
/// binary) so tests can drive real NSXPC in-process.
///
/// Start/stop arrive on XPC's queue in call order, but two fire-and-forget
/// Tasks could reach the broadcaster reordered — so commands flow through
/// one AsyncStream consumed by one pump task, preserving XPC's ordering.
public final class DaemonXPCService: NSObject, LoupeDaemonXPCProtocol, @unchecked Sendable {
    private enum Command: Sendable {
        case start(any TelemetrySource, XPCReceiverBox)
        case stop(@Sendable (Data) -> Void)
    }

    private let box: XPCReceiverBox?
    private let daemonVersion: String
    private let makeSource: TelemetrySourceFactory
    private let commands: AsyncStream<Command>.Continuation
    private let pump: Task<Void, Never>
    private let negotiation = NSLock()
    private var isProtocolNegotiated = false

    public init(
        remoteReceiver: (any LoupeSampleReceiverXPCProtocol)?,
        daemonVersion: String,
        makeSource: @escaping TelemetrySourceFactory
    ) {
        self.box = remoteReceiver.map(XPCReceiverBox.init)
        self.daemonVersion = daemonVersion
        self.makeSource = makeSource
        let (stream, continuation) = AsyncStream.makeStream(
            of: Command.self, bufferingPolicy: .bufferingNewest(64))
        self.commands = continuation
        let broadcaster = SampleBroadcaster()
        self.pump = Task {
            for await command in stream {
                switch command {
                case .start(let source, let box):
                    await broadcaster.start(source: source, box: box)
                case .stop(let reply):
                    reply(await broadcaster.stop() ?? Data())
                }
            }
            _ = await broadcaster.stop()
        }
    }

    deinit {
        commands.finish()
    }

    public func handshake(
        clientProtocolVersion: Int, reply: @escaping @Sendable (Data) -> Void
    ) {
        guard clientProtocolVersion == EventProtocol.version else {
            reply(Data())
            return
        }
        negotiation.withLock { isProtocolNegotiated = true }
        let handshake = DaemonHandshake(
            daemonVersion: daemonVersion,
            protocolVersion: EventProtocol.version,
            pid: ProcessInfo.processInfo.processIdentifier)
        reply((try? JSONEncoder().encode(handshake)) ?? Data())
    }

    public func startSampleStream(intervalMs: Int) {
        guard negotiation.withLock({ isProtocolNegotiated }), let box else { return }
        let source = makeSource(Sampling.clampedCadence(intervalMs: intervalMs))
        enqueue(.start(source, box))
    }

    public func stopSampleStream(reply: @escaping @Sendable (Data) -> Void) {
        enqueue(.stop(reply))
    }

    /// Ends streaming and the pump; called when the connection dies.
    public func shutdown() {
        commands.finish()
    }

    private func enqueue(_ command: Command) {
        // A signed client can still be buggy. Keep root-owned memory bounded
        // and fail closed if it floods start/stop faster than the actor can
        // apply them. Finishing drains the bounded prefix, then stops the
        // broadcaster at the end of the pump.
        if case .dropped = commands.yield(command) {
            commands.finish()
        }
    }
}

/// Synchronous connection gate used before any root-owned object is exported.
/// Production requires the active console UID and the app's designated code
/// requirement. Tests inject the explicit current-process policy because
/// anonymous XPC endpoints are intentionally unsigned.
public struct DaemonPeerValidator: @unchecked Sendable {
    private let validateConnection: @Sendable (NSXPCConnection) -> Bool

    public init(validate: @escaping @Sendable (NSXPCConnection) -> Bool) {
        self.validateConnection = validate
    }

    public func accepts(_ connection: NSXPCConnection) -> Bool {
        validateConnection(connection)
    }

    public static let currentProcessForTesting = DaemonPeerValidator { connection in
        connection.processIdentifier == ProcessInfo.processInfo.processIdentifier
            && connection.effectiveUserIdentifier == geteuid()
    }

    public static func production(appBundleIdentifier: String) -> DaemonPeerValidator {
        DaemonPeerValidator { connection in
            guard connection.processIdentifier > 0,
                let consoleUID = activeConsoleUserID(),
                connection.effectiveUserIdentifier == consoleUID,
                let teamIdentifier = ownTeamIdentifier(),
                teamIdentifier.count == 10,
                teamIdentifier.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }),
                !appBundleIdentifier.isEmpty,
                appBundleIdentifier.allSatisfy({
                    $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-")
                })
            else { return false }

            let requirement =
                "identifier \"\(appBundleIdentifier)\" and anchor apple generic "
                + "and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
            connection.setCodeSigningRequirement(requirement)
            return true
        }
    }
}

private func activeConsoleUserID() -> uid_t? {
    var metadata = stat()
    guard stat("/dev/console", &metadata) == 0, metadata.st_uid != 0 else { return nil }
    return metadata.st_uid
}

private func ownTeamIdentifier() -> String? {
    var dynamicCode: SecCode?
    guard SecCodeCopySelf(SecCSFlags(), &dynamicCode) == errSecSuccess,
        let dynamicCode
    else { return nil }

    var staticCode: SecStaticCode?
    guard SecCodeCopyStaticCode(dynamicCode, SecCSFlags(), &staticCode) == errSecSuccess,
        let staticCode
    else { return nil }

    var information: CFDictionary?
    guard
        SecCodeCopySigningInformation(
            staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
            == errSecSuccess,
        let dictionary = information as? [String: Any]
    else { return nil }
    return dictionary[kSecCodeInfoTeamIdentifier as String] as? String
}

/// Accepts connections for both the mach-service listener (daemon) and
/// anonymous listeners (tests).
public final class DaemonListenerDelegate: NSObject, NSXPCListenerDelegate, Sendable {
    private let daemonVersion: String
    private let makeSource: TelemetrySourceFactory
    private let peerValidator: DaemonPeerValidator
    private let connectionLimiter: ConnectionLimiter

    /// No default source: which telemetry backs the daemon is a composition
    /// decision that belongs at the composition root, visibly.
    public init(
        daemonVersion: String,
        peerValidator: DaemonPeerValidator,
        maxConnections: Int = 4,
        makeSource: @escaping TelemetrySourceFactory
    ) {
        self.daemonVersion = daemonVersion
        self.peerValidator = peerValidator
        self.connectionLimiter = ConnectionLimiter(maximum: maxConnections)
        self.makeSource = makeSource
    }

    public func listener(
        _ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        guard peerValidator.accepts(newConnection),
            let lease = connectionLimiter.acquire()
        else { return false }
        newConnection.exportedInterface = NSXPCInterface(with: LoupeDaemonXPCProtocol.self)
        newConnection.remoteObjectInterface = NSXPCInterface(
            with: LoupeSampleReceiverXPCProtocol.self)
        guard let receiver = newConnection.remoteObjectProxy as? LoupeSampleReceiverXPCProtocol
        else {
            lease.release()
            return false
        }
        let service = DaemonXPCService(
            remoteReceiver: receiver, daemonVersion: daemonVersion, makeSource: makeSource)
        newConnection.exportedObject = service
        // A crashed or force-quit client never sends stopSampleStream; the
        // daemon must notice on its own or it samples forever as root.
        let endConnection: @Sendable () -> Void = {
            service.shutdown()
            lease.release()
        }
        newConnection.interruptionHandler = endConnection
        newConnection.invalidationHandler = endConnection
        newConnection.resume()
        return true
    }
}
