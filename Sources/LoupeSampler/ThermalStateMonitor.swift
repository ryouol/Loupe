import Foundation
import LoupeCore
import LoupeTelemetry

/// Push-based thermal state changes (vs. the sampler's polled reads): the
/// cooldown gate between benchmark runs waits on these instead of spinning.
public enum ThermalStateMonitor {
    /// Current state first, then every change until cancelled.
    public static func states() -> AsyncStream<ThermalState> {
        AsyncStream { continuation in
            continuation.yield(ThermalState(platform: ProcessInfo.processInfo.thermalState))
            let task = Task {
                let notifications = NotificationCenter.default.notifications(
                    named: ProcessInfo.thermalStateDidChangeNotification)
                for await _ in notifications {
                    if Task.isCancelled { break }
                    continuation.yield(
                        ThermalState(platform: ProcessInfo.processInfo.thermalState))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
