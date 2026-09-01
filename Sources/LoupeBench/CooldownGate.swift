import LoupeCore

private actor CooldownObservation {
    private var nominalSince: ContinuousClock.Instant?

    func observe(_ state: ThermalState, at instant: ContinuousClock.Instant) {
        if state == .nominal {
            if nominalSince == nil { nominalSince = instant }
        } else {
            nominalSince = nil
        }
    }

    func isStable(at instant: ContinuousClock.Instant, for dwell: Duration) -> Bool {
        guard let nominalSince else { return false }
        return instant - nominalSince >= dwell
    }
}

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
            let observation = CooldownObservation()
            group.addTask {
                for await state in states {
                    await observation.observe(state, at: clock.now)
                }
                // Stream ended without reaching nominal: treat as timeout
                // rather than spinning forever on a dead stream.
                return .timedOut
            }
            group.addTask {
                let cadence: Duration =
                    stableFor < .milliseconds(100) ? .milliseconds(5) : .milliseconds(100)
                while !Task.isCancelled {
                    if await observation.isStable(at: clock.now, for: stableFor) {
                        return .nominal
                    }
                    try? await clock.sleep(for: cadence)
                }
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
