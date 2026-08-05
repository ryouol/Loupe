import Darwin

/// Converts `mach_continuous_time()` ticks to nanoseconds.
///
/// `numer`/`denom` are injectable so conversion is testable on any machine;
/// production code uses `.live()`. All Loupe timestamps are continuous-clock
/// nanoseconds — never `Date`, never `mach_absolute_time` (it stops during
/// sleep, which would silently skew every cross-process correlation).
public struct Timebase: Sendable, Equatable {
    public let numer: UInt32
    public let denom: UInt32

    public init(numer: UInt32, denom: UInt32) {
        precondition(numer > 0 && denom > 0, "mach timebase ratios are never zero")
        self.numer = numer
        self.denom = denom
    }

    public static func live() -> Timebase {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Timebase(numer: info.numer, denom: info.denom)
    }

    /// Exact floor(ticks * numer / denom) without the naive `ticks * numer`
    /// overflow: splitting at the division keeps every intermediate in range
    /// until uptime exceeds ~590 years on Apple Silicon (numer 125, denom 3).
    public func nanoseconds(fromTicks ticks: UInt64) -> UInt64 {
        let n = UInt64(numer)
        let d = UInt64(denom)
        if n == d { return ticks }
        let quotient = ticks / d
        let remainder = ticks % d
        return quotient * n + (remainder * n) / d
    }

    /// The single place production code reads the live clock; everything else
    /// takes tick values as data so tests never depend on real time.
    public static func nowContinuousTicks() -> UInt64 {
        mach_continuous_time()
    }

    public func nowNanoseconds() -> UInt64 {
        nanoseconds(fromTicks: Self.nowContinuousTicks())
    }
}

/// Result of a clock-offset handshake: how far a remote clock (an adapter's)
/// sits from ours, in nanoseconds, with an explicit error bound.
public struct ClockOffsetEstimate: Sendable, Equatable {
    /// remote − local. Add to a local timestamp to express it on the remote
    /// clock; subtract from a remote timestamp to map it onto ours.
    public let offsetNs: Int64
    /// Half the round trip: the NTP guarantee is |true − offsetNs| ≤ this,
    /// regardless of how asymmetric the two path delays actually were.
    public let uncertaintyNs: UInt64

    public init(offsetNs: Int64, uncertaintyNs: UInt64) {
        self.offsetNs = offsetNs
        self.uncertaintyNs = uncertaintyNs
    }
}

/// One NTP-style four-timestamp exchange. t0/t3 are on the local clock,
/// t1/t2 on the remote clock; all are continuous-time nanoseconds.
public struct ClockSyncSample: Sendable, Equatable {
    public let t0: UInt64
    public let t1: UInt64
    public let t2: UInt64
    public let t3: UInt64

    public init(t0: UInt64, t1: UInt64, t2: UInt64, t3: UInt64) {
        self.t0 = t0
        self.t1 = t1
        self.t2 = t2
        self.t3 = t3
    }

    /// Returns nil instead of trapping on acausal samples (t3 < t0, remote
    /// receive after send, or negative path time) — handshake peers are
    /// adapters, i.e. untrusted input.
    public func estimate() -> ClockOffsetEstimate? {
        // Two's-complement subtraction stays exact as long as true deltas fit
        // Int64 — guaranteed for ns-since-boot values (< 2^63 ≈ 292 years).
        let localSpan = Int64(bitPattern: t3 &- t0)
        let remoteSpan = Int64(bitPattern: t2 &- t1)
        guard localSpan >= 0, remoteSpan >= 0, localSpan >= remoteSpan else { return nil }

        let upstream = Int64(bitPattern: t1 &- t0)
        let downstream = Int64(bitPattern: t2 &- t3)
        let roundTrip = localSpan - remoteSpan
        return ClockOffsetEstimate(
            offsetNs: (upstream + downstream) / 2,
            uncertaintyNs: UInt64(roundTrip) / 2
        )
    }
}

public enum ClockOffsetEstimator {
    /// The min-RTT sample carries the tightest bound, so a burst of exchanges
    /// beats any averaging scheme that mixes in congested round trips.
    public static func best(of samples: [ClockSyncSample]) -> ClockOffsetEstimate? {
        samples.compactMap { $0.estimate() }.min { $0.uncertaintyNs < $1.uncertaintyNs }
    }
}
