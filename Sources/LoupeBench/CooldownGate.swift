import LoupeCore

/// Between benchmark runs the machine must return to thermal nominal or the
/// next run measures the previous run's heat. The gate must never hang: a
/// machine that won't cool (small chassis, hot room) times out cleanly and
/// the report proceeds with that fact on record.
public enum CooldownGate {
    public enum Outcome: Sendable, Equatable {
        case nominal
        case timedOut
    }

    public static func waitForNominal(
        states: AsyncStream<ThermalState>,
        timeout: Duration,
        clock: ContinuousClock = ContinuousClock()
    ) async -> Outcome {
        await withTaskGroup(of: Outcome.self) { group in
            group.addTask {
                for await state in states where state == .nominal {
                    return .nominal
                }
                // Stream ended without reaching nominal: treat as timeout
                // rather than spinning forever on a dead stream.
                return .timedOut
            }
            group.addTask {
                try? await clock.sleep(for: timeout)
                return .timedOut
            }
            let first = await group.next() ?? .timedOut
            group.cancelAll()
            return first
        }
    }
}
