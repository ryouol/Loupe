import XCTest

@testable import LoupeCore

/// Deterministic RNG so jitter-based tests never flake.
private struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { self.state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

final class TimebaseTests: XCTestCase {

    // MARK: Conversion

    func testIdentityTimebasePassesTicksThrough() {
        let tb = Timebase(numer: 1, denom: 1)
        XCTAssertEqual(tb.nanoseconds(fromTicks: 0), 0)
        XCTAssertEqual(tb.nanoseconds(fromTicks: 123_456_789), 123_456_789)
        XCTAssertEqual(tb.nanoseconds(fromTicks: UInt64.max), UInt64.max)
    }

    func testAppleSiliconTimebaseKnownValues() {
        // 125/3 is the ratio on every Apple Silicon generation so far.
        let tb = Timebase(numer: 125, denom: 3)
        XCTAssertEqual(tb.nanoseconds(fromTicks: 0), 0)
        XCTAssertEqual(tb.nanoseconds(fromTicks: 3), 125)
        XCTAssertEqual(tb.nanoseconds(fromTicks: 24_000_000), 1_000_000_000)
        XCTAssertEqual(tb.nanoseconds(fromTicks: 1), 41)  // floor(125/3)
        XCTAssertEqual(tb.nanoseconds(fromTicks: 2), 83)  // floor(250/3)
    }

    func testUnrepresentableInjectedRatioSaturates() {
        let timebase = Timebase(numer: UInt32.max, denom: 1)
        XCTAssertEqual(timebase.nanoseconds(fromTicks: UInt64.max), UInt64.max)
    }

    func testConversionIsExactFloorAgainst128BitReference() {
        var rng = SplitMix64(seed: 0xB0)
        let timebases = [
            Timebase(numer: 125, denom: 3),
            Timebase(numer: 1, denom: 1),
            Timebase(numer: 1_000_000_000, denom: 33_333_333),
            Timebase(numer: 3, denom: 125),
        ]
        for tb in timebases {
            // Constrain ticks so the true result fits UInt64; correctness
            // beyond that range is out of contract (documented in type).
            // A shrinking ratio (numer < denom) can never overflow the result.
            let bound =
                tb.numer >= tb.denom
                ? UInt64.max / UInt64(tb.numer) * UInt64(tb.denom)
                : UInt64.max
            for _ in 0..<2_000 {
                let ticks = UInt64.random(in: 0...bound, using: &rng)
                let ns = tb.nanoseconds(fromTicks: ticks)
                assertIsExactFloor(ticks: ticks, ns: ns, tb: tb)
            }
        }
    }

    /// floor correctness without 128-bit division: ns is the floor of
    /// ticks*numer/denom iff ns*denom ≤ ticks*numer < (ns+1)*denom.
    private func assertIsExactFloor(ticks: UInt64, ns: UInt64, tb: Timebase) {
        let lhs = ns.multipliedFullWidth(by: UInt64(tb.denom))
        let rhs = ticks.multipliedFullWidth(by: UInt64(tb.numer))
        XCTAssertTrue(
            lessOrEqual(lhs, rhs),
            "ns too large for ticks=\(ticks) tb=\(tb.numer)/\(tb.denom)")
        let upper = add(lhs, UInt64(tb.denom))
        XCTAssertTrue(
            lessThan(rhs, upper),
            "ns too small for ticks=\(ticks) tb=\(tb.numer)/\(tb.denom)")
    }

    private typealias Wide = (high: UInt64, low: UInt64.Magnitude)

    private func lessThan(_ a: Wide, _ b: Wide) -> Bool {
        a.high != b.high ? a.high < b.high : a.low < b.low
    }

    private func lessOrEqual(_ a: Wide, _ b: Wide) -> Bool {
        !lessThan(b, a)
    }

    private func add(_ a: Wide, _ b: UInt64) -> Wide {
        let (low, carry) = a.low.addingReportingOverflow(b)
        return (a.high &+ (carry ? 1 : 0), low)
    }

    func testConversionIsMonotone() {
        var rng = SplitMix64(seed: 42)
        let tb = Timebase(numer: 125, denom: 3)
        // Stay inside the representable result range (~2^57 ticks for 125/3).
        let bound = UInt64.max / UInt64(tb.numer) * UInt64(tb.denom)
        for _ in 0..<2_000 {
            let a = UInt64.random(in: 0...bound, using: &rng)
            let b = UInt64.random(in: 0...bound, using: &rng)
            let (lo, hi) = a <= b ? (a, b) : (b, a)
            XCTAssertLessThanOrEqual(
                tb.nanoseconds(fromTicks: lo), tb.nanoseconds(fromTicks: hi))
        }
    }

    // MARK: Live clock

    func testLiveClockIsMonotonicAndTimebaseSane() {
        let tb = Timebase.live()
        XCTAssertGreaterThan(tb.numer, 0)
        XCTAssertGreaterThan(tb.denom, 0)
        var previous = Timebase.nowContinuousTicks()
        for _ in 0..<1_000 {
            let now = Timebase.nowContinuousTicks()
            XCTAssertGreaterThanOrEqual(now, previous)
            previous = now
        }
        XCTAssertGreaterThan(tb.nowNanoseconds(), 0)
    }

    // MARK: Offset estimation

    func testSymmetricExchangeRecoversExactOffset() {
        // Remote clock is exactly +500µs; both path delays equal, so the
        // estimator must land on the true offset with uncertainty == delay.
        let offset: Int64 = 500_000
        let sample = makeSample(
            t0: 1_000_000, delayUp: 40_000, remoteProcessing: 10_000, delayDown: 40_000,
            trueOffset: offset)
        let estimate = sample.estimate()
        XCTAssertEqual(estimate?.offsetNs, offset)
        XCTAssertEqual(estimate?.uncertaintyNs, 40_000)
    }

    func testNegativeOffsetIsRecovered() {
        let offset: Int64 = -2_000_000
        let sample = makeSample(
            t0: 50_000_000, delayUp: 15_000, remoteProcessing: 5_000, delayDown: 15_000,
            trueOffset: offset)
        XCTAssertEqual(sample.estimate()?.offsetNs, offset)
    }

    func testEstimateErrorIsBoundedByUncertaintyUnderJitter() {
        // The NTP bound |error| ≤ RTT/2 must hold for arbitrary asymmetric
        // delays, not just symmetric ones. 10k adversarial trials.
        var rng = SplitMix64(seed: 7)
        for trial in 0..<10_000 {
            let trueOffset = Int64.random(in: -5_000_000_000...5_000_000_000, using: &rng)
            let sample = makeSample(
                t0: UInt64.random(in: 10_000_000_000..<20_000_000_000, using: &rng),
                delayUp: UInt64.random(in: 1_000..<3_000_000, using: &rng),
                remoteProcessing: UInt64.random(in: 0..<200_000, using: &rng),
                delayDown: UInt64.random(in: 1_000..<3_000_000, using: &rng),
                trueOffset: trueOffset)
            guard let estimate = sample.estimate() else {
                XCTFail("causal sample must estimate (trial \(trial))")
                return
            }
            let error = (estimate.offsetNs - trueOffset).magnitude
            XCTAssertLessThanOrEqual(
                error, estimate.uncertaintyNs,
                "NTP bound violated in trial \(trial)")
        }
    }

    func testEstimatorToleratesSlowClockSkew() {
        // 50 ppm skew over a ~100µs exchange shifts the remote timestamps by
        // only a few ns — the estimate must stay within uncertainty + 10ns.
        let skew = 50e-6
        let trueOffset: Int64 = 1_000_000
        let t0: UInt64 = 3_600_000_000_000
        let delayUp: UInt64 = 50_000
        let processing: UInt64 = 20_000
        let delayDown: UInt64 = 50_000

        func remoteClock(_ localNs: UInt64) -> UInt64 {
            let drifted = Double(localNs) * (1.0 + skew)
            return UInt64(drifted) &+ UInt64(bitPattern: trueOffset)
        }

        let t1 = remoteClock(t0 + delayUp)
        let t2 = remoteClock(t0 + delayUp + processing)
        let t3 = t0 + delayUp + processing + delayDown
        guard let estimate = ClockSyncSample(t0: t0, t1: t1, t2: t2, t3: t3).estimate() else {
            XCTFail("skewed but causal sample must estimate")
            return
        }
        // Absolute skew contribution: the remote clock reads t*skew ahead,
        // which is huge at t=1h, but it is indistinguishable from offset —
        // the *estimator's* job is only to be consistent with the bound.
        let apparentOffset = Int64(Double(t0) * skew) + trueOffset
        let error = (estimate.offsetNs - apparentOffset).magnitude
        XCTAssertLessThanOrEqual(error, estimate.uncertaintyNs + 10)
    }

    func testBestOfBurstPicksMinimumRoundTrip() {
        let offset: Int64 = 250_000
        var samples: [ClockSyncSample] = []
        for delay in [900_000, 30_000, 400_000] as [UInt64] {
            samples.append(
                makeSample(
                    t0: 1_000_000_000, delayUp: delay, remoteProcessing: 1_000,
                    delayDown: delay, trueOffset: offset))
        }
        let best = ClockOffsetEstimator.best(of: samples)
        XCTAssertEqual(best?.uncertaintyNs, 30_000)
        XCTAssertEqual(best?.offsetNs, offset)
    }

    func testAcausalSamplesAreRejectedNotTrapped() {
        // t3 before t0: local span negative.
        XCTAssertNil(ClockSyncSample(t0: 100, t1: 200, t2: 210, t3: 50).estimate())
        // Remote span exceeds local span: negative RTT.
        XCTAssertNil(ClockSyncSample(t0: 100, t1: 200, t2: 900, t3: 150).estimate())
        // Remote send before remote receive.
        XCTAssertNil(ClockSyncSample(t0: 100, t1: 500, t2: 400, t3: 300).estimate())
        // Garbage from an untrusted adapter must yield nil, never a crash.
        XCTAssertNil(
            ClockOffsetEstimator.best(of: [ClockSyncSample(t0: .max, t1: 0, t2: .max, t3: 0)]))
        XCTAssertNil(ClockOffsetEstimator.best(of: []))
    }

    func testClockOffsetAverageCannotOverflow() {
        let positive = UInt64(Int64.max)
        XCTAssertEqual(
            ClockSyncSample(t0: 0, t1: positive, t2: positive, t3: 0).estimate()?.offsetNs,
            Int64.max)
        let negative = UInt64(bitPattern: Int64.min)
        XCTAssertEqual(
            ClockSyncSample(t0: 0, t1: negative, t2: negative, t3: 0).estimate()?.offsetNs,
            Int64.min)
    }

    // MARK: Helpers

    private func makeSample(
        t0: UInt64, delayUp: UInt64, remoteProcessing: UInt64, delayDown: UInt64,
        trueOffset: Int64
    ) -> ClockSyncSample {
        let offsetBits = UInt64(bitPattern: trueOffset)
        let t1 = (t0 + delayUp) &+ offsetBits
        let t2 = t1 + remoteProcessing
        let t3 = t0 + delayUp + remoteProcessing + delayDown
        return ClockSyncSample(t0: t0, t1: t1, t2: t2, t3: t3)
    }
}
