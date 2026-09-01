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
    /// Bundle identifier enforced by the privileged listener's designated
    /// requirement. The team identifier is derived from the helper's own
    /// signature at runtime; it is never committed to source.
    public static let appBundleIdentifier = "ai.squint.loupe"
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
    /// Replies with JSON-encoded `DaemonHandshake`; an empty reply means the
    /// client protocol version is unsupported.
    func handshake(clientProtocolVersion: Int, reply: @escaping @Sendable (Data) -> Void)
    func startSampleStream(intervalMs: Int)
    /// Stops the producer and replies with its terminal acquisition summary.
    /// Empty data means the accounting window could not be closed.
    func stopSampleStream(reply: @escaping @Sendable (Data) -> Void)
}

/// App-exported receiver interface (daemon → app).
@objc public protocol LoupeSampleReceiverXPCProtocol {
    /// One JSON-encoded `SystemSample` per call.
    func deliver(sampleData: Data)
    /// Terminal JSON-encoded `TelemetryAcquisitionStats`. If this message is
    /// absent, the app reports helper acquisition integrity as unknown.
    func deliver(summaryData: Data)
}
