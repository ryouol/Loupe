import Foundation
import LoupeCore

/// App-exported receiver: decodes incoming sample Data and feeds a stream.
/// Safe to mark Sendable — its only state is the continuation, which is
/// Sendable and thread-safe, and NSXPC may call deliver on any queue.
final class SampleReceiver: NSObject, LoupeSampleReceiverXPCProtocol, @unchecked Sendable {
    private let continuation: AsyncStream<SystemSample>.Continuation

    init(continuation: AsyncStream<SystemSample>.Continuation) {
        self.continuation = continuation
    }

    func deliver(sampleData: Data) {
        // The daemon is trusted, but decode defensively anyway: a malformed
        // sample is dropped, never fatal.
        if let sample = try? JSONDecoder().decode(SystemSample.self, from: sampleData) {
            continuation.yield(sample)
        }
    }
}

/// Client half of the XPC boundary. Wraps one NSXPCConnection; `samples()`
/// starts the daemon's stream and yields until the connection dies or the
/// consumer cancels. NSXPCConnection is documented thread-safe.
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
            guard
                let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
                    continuation.resume(returning: nil)
                }) as? LoupeDaemonXPCProtocol
            else {
                continuation.resume(returning: nil)
                return
            }
            proxy.handshake { data in
                continuation.resume(
                    returning: try? JSONDecoder().decode(DaemonHandshake.self, from: data))
            }
        }
    }

    /// Must be called before `handshake()`/`samples()`; separate from init so
    /// the receiver can be installed against the not-yet-resumed connection.
    public func activate() -> AsyncStream<SystemSample> {
        let (stream, continuation) = AsyncStream.makeStream(of: SystemSample.self)
        connection.exportedObject = SampleReceiver(continuation: continuation)
        connection.interruptionHandler = { continuation.finish() }
        connection.invalidationHandler = { continuation.finish() }
        connection.resume()
        // Connection lifetime is deliberately NOT tied to the stream: a
        // caller may handshake without ever consuming samples. Owners end
        // the connection explicitly via stopAndInvalidate().
        return stream
    }

    public func startStream(intervalMs: Int = 100) {
        (connection.remoteObjectProxy as? LoupeDaemonXPCProtocol)?
            .startSampleStream(intervalMs: intervalMs)
    }

    public func stopAndInvalidate() {
        (connection.remoteObjectProxy as? LoupeDaemonXPCProtocol)?.stopSampleStream()
        connection.invalidate()
    }
}
