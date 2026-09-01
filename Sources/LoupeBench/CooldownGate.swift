import LoupeCore

/// Between benchmark runs the machine must return to thermal nominal or the
/// next run measures the previous run's heat. The gate must never hang: a
/// machine that won't cool (small chassis, hot room) times out cleanly and
/// the benchmark harness refuses to publish a compromised report.
public enum CooldownGate {
    public enum Outcome: Sendable, Equatable {
        case nominal
        case timedOut
    }

    public static func waitForNominal(
        states: AsyncStream<ThermalState>,
        timeout: Duration,
        stableFor: Duration = .seconds(3),
        clock: ContinuousClock = ContinuousClock()
    ) async -> Outcome {
        await withTaskGroup(of: Outcome.self) { group in
            group.addTask {
                var nominalSince: ContinuousClock.Instant?
                for await state in states {
                    if state == .nominal {
                        let now = clock.now
                        if nominalSince == nil { nominalSince = now }
                        if let nominalSince, now - nominalSince >= stableFor {
                            return .nominal
                        }
                    } else {
                        nominalSince = nil
                    }
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
