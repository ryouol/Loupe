import Foundation

/// Environment contract between the Makefile and the app.
public enum LoupeEnvironment {
    /// Base path of a session pair to open at launch (`make replay`).
    public static let replaySessionVariable = "LOUPE_REPLAY_FIXTURE"
}

/// A recorded session is a file pair: `<base>.ndjson` (protocol events) and
/// `<base>.system.ndjson` (telemetry samples). This type is the only owner
/// of that convention — every layer that opens, drops, or records sessions
/// goes through it.
public struct SessionFilePair: Sendable, Equatable {
    public static let eventsSuffix = ".ndjson"
    public static let systemSuffix = ".system.ndjson"

    public let basePath: String

    public init(basePath: String) {
        self.basePath = basePath
    }

    /// Either file of the pair identifies the session.
    public init(anyFileURL url: URL) {
        let path = url.path
        if path.hasSuffix(Self.systemSuffix) {
            self.basePath = String(path.dropLast(Self.systemSuffix.count))
        } else if path.hasSuffix(Self.eventsSuffix) {
            self.basePath = String(path.dropLast(Self.eventsSuffix.count))
        } else {
            self.basePath = path
        }
    }

    public var eventsURL: URL { URL(fileURLWithPath: basePath + Self.eventsSuffix) }
    public var systemURL: URL { URL(fileURLWithPath: basePath + Self.systemSuffix) }
    public var name: String { URL(fileURLWithPath: basePath).lastPathComponent }
}
