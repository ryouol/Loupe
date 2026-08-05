import LoupeCore

/// The seam that keeps everything testable without root or hardware: live
/// and replay implementations are interchangeable.
public protocol TelemetrySource: Actor {
    func stream() -> AsyncStream<SystemSample>
}
