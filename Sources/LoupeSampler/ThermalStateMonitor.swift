import Foundation
import LoupeCore
import LoupeTelemetry

/// Periodic thermal observations for the benchmark cooldown dwell gate.
public enum ThermalStateMonitor {
    /// Current state first, then a bounded 4 Hz stream until cancelled.
    public static func states() -> AsyncStream<ThermalState> {
        AsyncStream(bufferingPolicy: .bufferingNewest(16)) { continuation in
            let task = Task {
                while !Task.isCancelled {
                    let result = continuation.yield(
                        ThermalState(platform: ProcessInfo.processInfo.thermalState))
                    if case .terminated = result { break }
                    try? await Task.sleep(for: .milliseconds(250))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
