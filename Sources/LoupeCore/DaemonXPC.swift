import Foundation

/// Shared constants and wire types for the app ↔ daemon XPC boundary.
/// These protocols must be @objc (NSXPCInterface requires it); payloads
/// cross as JSON-encoded Data of LoupeCore Codable types so the ObjC
/// surface stays as thin as possible.
public enum LoupeDaemon {
    /// Must match both the LaunchDaemon plist filename and its Label key —
    /// SMAppService refuses anything else. A LoupeCoreTests contract test
    /// pins the committed plist to these constants.
    public static let machServiceName = "ai.squint.loupe.daemon"
    public static let plistName = machServiceName + ".plist"
    /// Runtime adapters connect here (mirrored in loupe_mlx/adapter.py).
    public static let adapterSocketPath = "/var/run/ai.squint.loupe.sock"
}

/// First message on every connection; proves protocol compatibility before
/// any streaming starts.
public struct DaemonHandshake: Codable, Sendable, Equatable {
    public let daemonVersion: String
    public let protocolVersion: Int
    public let pid: Int32

    public init(daemonVersion: String, protocolVersion: Int, pid: Int32) {
        self.daemonVersion = daemonVersion
        self.protocolVersion = protocolVersion
        self.pid = pid
    }
}

/// Daemon-exported interface (app → daemon).
@objc public protocol LoupeDaemonXPCProtocol {
    /// Replies with JSON-encoded `DaemonHandshake`.
    func handshake(reply: @escaping @Sendable (Data) -> Void)
    func startSampleStream(intervalMs: Int)
    func stopSampleStream()
}

/// App-exported receiver interface (daemon → app).
@objc public protocol LoupeSampleReceiverXPCProtocol {
    /// One JSON-encoded `SystemSample` per call.
    func deliver(sampleData: Data)
}
