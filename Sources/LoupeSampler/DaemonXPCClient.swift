import Foundation
import LoupeCore

/// App-exported receiver. @unchecked is safe: its only state is the
/// continuation, which is Sendable, and NSXPC calls deliver on any queue.
final class SampleReceiver: NSObject, LoupeSampleReceiverXPCProtocol, @unchecked Sendable {
    private let continuation: AsyncStream<SystemSample>.Continuation

    init(continuation: AsyncStream<SystemSample>.Continuation) {
        self.continuation = continuation
    }

    func deliver(sampleData: Data) {
        if let sample = try? JSONDecoder().decode(SystemSample.self, from: sampleData) {
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

    /// Call before `handshake()`/`startStream()`. Connection lifetime is
    /// deliberately not tied to the returned stream (callers may handshake
    /// without consuming samples); end it via `stopAndInvalidate()`.
    public func activate() -> AsyncStream<SystemSample> {
        let (stream, continuation) = AsyncStream.makeStream(of: SystemSample.self)
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
