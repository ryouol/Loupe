import LoupeCore

/// The seam that keeps everything testable without root or hardware: the
/// daemon consumes a `TelemetrySource` and never knows whether samples come
/// from IOReport or a recorded fixture.
public protocol TelemetrySource: Actor {
    func stream() -> AsyncStream<SystemSample>
}
