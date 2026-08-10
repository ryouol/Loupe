/// One entry of the correlated timeline: a telemetry sample or an inference
/// event, on the unified (daemon) clock.
public enum TimelineItem: Sendable, Equatable {
    case sample(SystemSample)
    case event(EventEnvelope)

    public var ts: UInt64 {
        switch self {
        case .sample(let sample): return sample.system.ts
        case .event(let envelope): return envelope.ts
        }
    }
}

public enum TimelineMerge {
    /// Joins both streams on the shared clock. `eventClockOffsetNs` follows
    /// `ClockOffsetEstimate` semantics (adapter − daemon): subtracting it
    /// maps event timestamps onto the sample clock. Equal timestamps order
    /// sample-before-event so consumers see state before the transition.
    public static func merge(
        samples: [SystemSample],
        events: [EventEnvelope],
        eventClockOffsetNs: Int64 = 0
    ) -> [TimelineItem] {
        let shiftedEvents = events.map { envelope in
            EventEnvelope(
                ts: shifted(envelope.ts, byRemovingOffset: eventClockOffsetNs),
                runId: envelope.runId,
                requestId: envelope.requestId,
                payload: envelope.payload)
        }
        var items = samples.map(TimelineItem.sample) + shiftedEvents.map(TimelineItem.event)
        items.sort { lhs, rhs in
            if lhs.ts != rhs.ts { return lhs.ts < rhs.ts }
            if case .sample = lhs, case .event = rhs { return true }
            return false
        }
        return items
    }

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
    static func shifted(_ ts: UInt64, byRemovingOffset offset: Int64) -> UInt64 {
        if offset >= 0 {
            let magnitude = UInt64(offset)
            return ts >= magnitude ? ts - magnitude : 0
        }
        let magnitude = UInt64(-offset)
        return ts <= UInt64.max - magnitude ? ts + magnitude : UInt64.max
    }
}
