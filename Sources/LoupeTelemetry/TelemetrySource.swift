import LoupeCore

/// The seam that keeps everything testable without root or hardware: live
/// and replay implementations are interchangeable.
public protocol TelemetrySource: Actor {
    func stream() -> AsyncStream<SystemSample>
    func acquisitionStats() -> TelemetryAcquisitionStats
}

extension TelemetrySource {
    /// Sources that predate protocol v2 or cannot close an accounting window
    /// report unknown. Callers must not turn that absence into zero loss.
    public func acquisitionStats() -> TelemetryAcquisitionStats { .unknown }
}

/// Chooses the telemetry implementation for a given cadence — the daemon's
/// composition root picks live vs replay here, never inside the XPC plumbing.
public typealias TelemetrySourceFactory = @Sendable (Duration) -> any TelemetrySource

/// Single owner of sampling cadence policy across app, daemon, and recorder.
public enum Sampling {
    public static let defaultIntervalMs = 100
    public static let minIntervalMs = 10
    public static let maxIntervalMs = 10_000
    public static var defaultCadence: Duration { .milliseconds(defaultIntervalMs) }
    public static var defaultHz: Double { 1_000.0 / Double(defaultIntervalMs) }

    public static func clampedCadence(intervalMs: Int) -> Duration {
        .milliseconds(max(minIntervalMs, min(intervalMs, maxIntervalMs)))
    }
}
