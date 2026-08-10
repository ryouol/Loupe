/// Clock-offset application for the correlated timeline: adapter event
/// timestamps map onto the daemon's sample clock before any lane renders.
/// Same-machine adapters emit degenerate clock_sync (offset 0), so this is
/// invisible today and load-bearing the day a remote-clock adapter appears.
public enum TimelineMerge {
    /// The session's own clock_sync events carry the handshake; the best
    /// (min-RTT) estimate wins. No sync events means same-clock, offset 0.
    public static func offset(fromClockSyncEvents events: [EventEnvelope]) -> Int64 {
        let samples = events.compactMap { envelope -> ClockSyncSample? in
            guard case .clockSync(let payload) = envelope.payload else { return nil }
            return payload.sample
        }
        return ClockOffsetEstimator.best(of: samples)?.offsetNs ?? 0
    }

    /// Saturating shift: a pathological offset must never wrap a timestamp
    /// around UInt64 — clamp to the clock's bounds instead.
    public static func shifted(_ ts: UInt64, byRemovingOffset offset: Int64) -> UInt64 {
        if offset >= 0 {
            let magnitude = UInt64(offset)
            return ts >= magnitude ? ts - magnitude : 0
        }
        let magnitude = UInt64(-offset)
        return ts <= UInt64.max - magnitude ? ts + magnitude : UInt64.max
    }
}
