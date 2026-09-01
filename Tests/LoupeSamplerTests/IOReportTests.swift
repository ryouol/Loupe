import Foundation
import XCTest

@testable import LoupeCore
@testable import LoupeSampler
@testable import LoupeTelemetry

/// The name-resolution and math rules, pure and hardware-free — this is
/// where cross-generation channel-name drift is caught.
final class IOReportLogicTests: XCTestCase {
    func testResolvesCanonicalAppleSiliconNames() {
        let selection = IOReportChannelLogic.resolve(
            energyChannels: ["CPU Energy", "GPU Energy", "ANE Energy", "DRAM Energy"],
            gpuStatsChannels: ["GPUPH", "Some Other Channel"])
        XCTAssertEqual(selection.gpuEnergy, "GPU Energy")
        XCTAssertEqual(selection.aneEnergy, "ANE Energy")
        XCTAssertEqual(selection.cpuEnergy, "CPU Energy")
        XCTAssertEqual(selection.gpuPerformanceStates, "GPUPH")
    }

    func testResolvesGenerationVariantNames() {
        // Some generations suffix the block index (ANE0) or rename the
        // perf-state channel; prefix matching must still find them.
        let selection = IOReportChannelLogic.resolve(
            energyChannels: ["CPU Energy", "GPU0 Energy", "ANE0 Energy"],
            gpuStatsChannels: ["GPU Performance States v2"])
        XCTAssertEqual(selection.gpuEnergy, "GPU0 Energy")
        XCTAssertEqual(selection.aneEnergy, "ANE0 Energy")
        XCTAssertEqual(selection.gpuPerformanceStates, "GPU Performance States v2")
    }

    func testMissingChannelsResolveToNilNotGarbage() {
        let selection = IOReportChannelLogic.resolve(
            energyChannels: ["CPU Energy"], gpuStatsChannels: [])
        XCTAssertNil(selection.gpuEnergy)
        XCTAssertNil(selection.aneEnergy)
        XCTAssertNil(selection.gpuPerformanceStates)
        XCTAssertEqual(selection.cpuEnergy, "CPU Energy")

        let empty = IOReportChannelLogic.resolve(energyChannels: [], gpuStatsChannels: [])
        XCTAssertEqual(empty, IOReportChannelLogic.Selection())
    }

    func testUnitConversionCoversKnownUnitsAndRejectsUnknown() {
        XCTAssertEqual(IOReportChannelLogic.millijoules(500, unitLabel: "mJ"), 500)
        XCTAssertEqual(IOReportChannelLogic.millijoules(500_000, unitLabel: "uJ"), 500)
        XCTAssertEqual(IOReportChannelLogic.millijoules(500_000_000, unitLabel: "nJ"), 500)
        XCTAssertEqual(IOReportChannelLogic.millijoules(500, unitLabel: " mJ "), 500)
        XCTAssertNil(IOReportChannelLogic.millijoules(500, unitLabel: "furlongs"))
        XCTAssertNil(IOReportChannelLogic.millijoules(-1, unitLabel: "mJ"))
    }

    func testPowerFromEnergyDelta() {
        // 500 mJ over 100 ms = 5 W = 5000 mW.
        XCTAssertEqual(
            IOReportChannelLogic.milliwatts(energyMillijoules: 500, intervalNs: 100_000_000),
            5_000)
        XCTAssertNil(IOReportChannelLogic.milliwatts(energyMillijoules: 500, intervalNs: 0))
        XCTAssertNil(IOReportChannelLogic.milliwatts(energyMillijoules: -1, intervalNs: 1))
    }

    func testBusyPercentFromResidencies() {
        let half = IOReportChannelLogic.busyPercent(states: [
            (name: "OFF", residency: 0), (name: "IDLE", residency: 500),
            (name: "P1", residency: 300), (name: "P2", residency: 200),
        ])
        XCTAssertEqual(half ?? -1, 50, accuracy: 0.001)

        XCTAssertNil(
            IOReportChannelLogic.busyPercent(states: []),
            "no states means unknown, not zero")
        XCTAssertNil(
            IOReportChannelLogic.busyPercent(states: [(name: "IDLE", residency: 0)]),
            "zero total residency means unknown, not zero")

        let saturated = IOReportChannelLogic.busyPercent(states: [
            (name: "IDLE", residency: 0), (name: "P1", residency: 100),
        ])
        XCTAssertEqual(saturated ?? -1, 100, accuracy: 0.001)

        let extreme = IOReportChannelLogic.busyPercent(states: [
            (name: "IDLE", residency: Int64.max),
            (name: "P1", residency: Int64.max),
        ])
        XCTAssertEqual(extreme ?? -1, 50, accuracy: 0.001)
    }

    func testAbsentReaderYieldsNilFieldsInSamples() {
        var tracker = CPUDeltaTracker()
        let sample = LiveTelemetrySource.takeSample(
            pid: nil, timebase: .live(), tracker: &tracker, power: PowerReading())
        XCTAssertNil(sample.system.gpuBusyPercent)
        XCTAssertNil(sample.system.gpuPowerMilliwatts)
        XCTAssertNil(sample.system.anePowerMilliwatts)
        XCTAssertNil(sample.system.packagePowerMilliwatts)
    }
}

/// Live probe: skips wherever IOReport or its channels are unavailable
/// (CI, denied contexts) — availability is exactly what must not be assumed.
final class IOReportLiveTests: XCTestCase {
    func testLiveReaderProducesPlausibleValuesWhenAvailable() async throws {
        guard let reader = IOReportPowerReader() else {
            throw XCTSkip("IOReport unavailable in this context")
        }
        _ = reader.sample()
        try await Task.sleep(for: .milliseconds(300))
        let reading = reader.sample()

        if let busy = reading.gpuBusyPercent {
            XCTAssertGreaterThanOrEqual(busy, 0)
            XCTAssertLessThanOrEqual(busy, 100)
        }
        for milliwatts in [
            reading.gpuPowerMilliwatts, reading.anePowerMilliwatts,
            reading.packagePowerMilliwatts,
        ].compactMap({ $0 }) {
            XCTAssertGreaterThanOrEqual(milliwatts, 0)
            XCTAssertLessThan(milliwatts, 200_000, "no Mac draws 200W package power")
        }
        XCTAssertFalse(
            reading == PowerReading(),
            "a working reader should resolve at least one channel")
    }
}
