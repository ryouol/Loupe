import Foundation
import LoupeCore
import LoupeTelemetry

private final class HandshakeContinuation: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<DaemonHandshake?, Never>?

    init(_ continuation: CheckedContinuation<DaemonHandshake?, Never>) {
        self.continuation = continuation
    }

    func resume(returning value: DaemonHandshake?) {
        let pending = lock.withLock { () -> CheckedContinuation<DaemonHandshake?, Never>? in
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(returning: value)
    }
}

/// App-exported receiver. @unchecked is safe: its only state is the
/// continuation, which is Sendable, and NSXPC calls deliver on any queue.
final class SampleReceiver: NSObject, LoupeSampleReceiverXPCProtocol, @unchecked Sendable {
    static let maxPayloadBytes = 65_536

    private let continuation: AsyncStream<SystemSample>.Continuation

    init(continuation: AsyncStream<SystemSample>.Continuation) {
        self.continuation = continuation
    }

    func deliver(sampleData: Data) {
        if sampleData.count <= Self.maxPayloadBytes,
            let sample = SystemSampleWireDecoder.decode(sampleData)
        {
            continuation.yield(sample)
        }
    }
}

/// Client half of the XPC boundary; NSXPCConnection is documented
/// thread-safe, hence @unchecked.
public final class DaemonXPCClient: @unchecked Sendable {
    public enum Endpoint {
        case machService(name: String, privileged: Bool)
        case anonymous(NSXPCListenerEndpoint)
    }

    private let connection: NSXPCConnection

    public init(
        endpoint: Endpoint = .machService(name: LoupeDaemon.machServiceName, privileged: true)
    ) {
        switch endpoint {
        case .machService(let name, let privileged):
            connection = NSXPCConnection(
                machServiceName: name, options: privileged ? .privileged : [])
        case .anonymous(let listenerEndpoint):
            connection = NSXPCConnection(listenerEndpoint: listenerEndpoint)
        }
        connection.remoteObjectInterface = NSXPCInterface(with: LoupeDaemonXPCProtocol.self)
        connection.exportedInterface = NSXPCInterface(with: LoupeSampleReceiverXPCProtocol.self)
    }

    public func handshake() async -> DaemonHandshake? {
        await withCheckedContinuation { continuation in
            let pending = HandshakeContinuation(continuation)
            Task {
                try? await Task.sleep(for: .seconds(3))
                pending.resume(returning: nil)
            }
            guard
                let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
                    pending.resume(returning: nil)
                }) as? LoupeDaemonXPCProtocol
            else {
                pending.resume(returning: nil)
                return
            }
            proxy.handshake(clientProtocolVersion: EventProtocol.version) { data in
                guard data.count <= 4_096,
                    let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                    Set(object.keys) == ["daemonVersion", "protocolVersion", "pid"],
                    let handshake = try? JSONDecoder().decode(DaemonHandshake.self, from: data),
                    handshake.protocolVersion == EventProtocol.version,
                    handshake.pid > 0,
                    !handshake.daemonVersion.isEmpty,
                    handshake.daemonVersion.utf8.count <= 128
                else {
                    pending.resume(returning: nil)
                    return
                }
                pending.resume(returning: handshake)
            }
        }
    }

    /// Call before `handshake()`/`startStream()`. Connection lifetime is
    /// deliberately not tied to the returned stream (callers may handshake
    /// without consuming samples); end it via `stopAndInvalidate()`.
    public func activate() -> AsyncStream<SystemSample> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: SystemSample.self, bufferingPolicy: .bufferingNewest(256))
        connection.exportedObject = SampleReceiver(continuation: continuation)
        connection.interruptionHandler = { continuation.finish() }
        connection.invalidationHandler = { continuation.finish() }
        connection.resume()
        return stream
    }

    public func startStream(intervalMs: Int = Sampling.defaultIntervalMs) {
        (connection.remoteObjectProxy as? LoupeDaemonXPCProtocol)?
            .startSampleStream(intervalMs: intervalMs)
    }

    public func stopAndInvalidate() {
        (connection.remoteObjectProxy as? LoupeDaemonXPCProtocol)?.stopSampleStream()
        connection.invalidate()
    }
}
