import Darwin

/// Converts `mach_continuous_time()` ticks to nanoseconds. Injectable ratio
/// for tests; never `mach_absolute_time` — it stops during sleep and would
/// silently skew cross-process correlation.
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

    /// Exact floor(ticks·numer/denom) while the result fits UInt64, otherwise
    /// saturated. The full-width product avoids the naive multiplication
    /// overflow (and makes injected/test ratios safe as well as live ones).
    public func nanoseconds(fromTicks ticks: UInt64) -> UInt64 {
        let n = UInt64(numer)
        let d = UInt64(denom)
        if n == d { return ticks }
        let product = ticks.multipliedFullWidth(by: n)
        guard product.high < d else { return UInt64.max }
        return d.dividingFullWidth(product).quotient
    }

    /// The one live clock read; everything else takes ticks as data.
    public static func nowContinuousTicks() -> UInt64 {
        mach_continuous_time()
    }

    public func nowNanoseconds() -> UInt64 {
        nanoseconds(fromTicks: Self.nowContinuousTicks())
    }
}

/// Remote-clock offset with its error bound.
public struct ClockOffsetEstimate: Sendable, Equatable {
    /// remote − local, ns; subtract from remote timestamps to map them here.
    public let offsetNs: Int64
    /// Half the RTT — the NTP bound |true − offsetNs| ≤ this holds for any
    /// path asymmetry.
    public let uncertaintyNs: UInt64

    public init(offsetNs: Int64, uncertaintyNs: UInt64) {
        self.offsetNs = offsetNs
        self.uncertaintyNs = uncertaintyNs
    }
}

/// One NTP-style exchange: t0/t3 local clock, t1/t2 remote clock, all ns.
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

    /// nil on acausal samples — handshake peers are untrusted adapters.
    public func estimate() -> ClockOffsetEstimate? {
        // Two's-complement diffs are exact while true deltas fit Int64
        // (ns-since-boot < 2^63 ≈ 292 years).
        let localSpan = Int64(bitPattern: t3 &- t0)
        let remoteSpan = Int64(bitPattern: t2 &- t1)
        guard localSpan >= 0, remoteSpan >= 0, localSpan >= remoteSpan else { return nil }

        let upstream = Int64(bitPattern: t1 &- t0)
        let downstream = Int64(bitPattern: t2 &- t3)
        let roundTrip = localSpan - remoteSpan
        // Compute (upstream + downstream) / 2 without overflowing when a
        // hostile clock sample places both deltas near an Int64 boundary.
        let averageOffset =
            upstream / 2 + downstream / 2 + (upstream % 2 + downstream % 2) / 2
        return ClockOffsetEstimate(
            offsetNs: averageOffset,
            uncertaintyNs: UInt64(roundTrip) / 2
        )
    }
}

public enum ClockOffsetEstimator {
    /// Min-RTT beats averaging: congested round trips only widen the bound.
    public static func best(of samples: [ClockSyncSample]) -> ClockOffsetEstimate? {
        samples.compactMap { $0.estimate() }.min { $0.uncertaintyNs < $1.uncertaintyNs }
    }
}
