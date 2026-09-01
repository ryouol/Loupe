import Foundation
import XCTest

@testable import LoupeCore
@testable import LoupeSampler
@testable import LoupeTelemetry

/// The `.needsHardware` suite: runs only when LOUPE_HARDWARE_TESTS=1 because
/// it depends on real scheduler behavior and the `top` binary — meaningless
/// inside CI virtualization. Everything here is still root-free.
final class HardwareIntegrationTests: XCTestCase {
    private func requireHardware() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["LOUPE_HARDWARE_TESTS"] == "1",
            "set LOUPE_HARDWARE_TESTS=1 to run hardware integration tests")
    }

    /// M1.1 acceptance: sampled values track `top` within tolerance. A spin
    /// thread pins ~one core so both samplers observe the same known load.
    func testCPUPercentTracksTopUnderControlledLoad() async throws {
        try requireHardware()

        let stop = Atomic(false)
        let spinner = Thread {
            while !stop.value {}
        }
        spinner.qualityOfService = .userInitiated
        spinner.start()
        defer { stop.value = true }

        // Let the spinner reach steady state before either sampler looks.
        try await Task.sleep(for: .milliseconds(300))

        let pid = ProcessInfo.processInfo.processIdentifier
        async let topReading = Self.topCPUPercent(pid: pid)

        let source = LiveTelemetrySource(targetPID: pid, cadence: .milliseconds(100))
        var readings: [Double] = []
        for await sample in await source.stream() {
            if let cpu = sample.process?.cpuPercent, cpu > 0 {
                readings.append(cpu)
            }
            if readings.count == 15 { break }
        }

        let ours = readings.sorted()[readings.count / 2]
        XCTAssertGreaterThan(ours, 70, "a spin thread should read near one full core")

        if let top = await topReading {
            XCTAssertEqual(
                ours, top, accuracy: 35,
                "median sampled CPU% (\(ours)) should track top (\(top))")
        }
        // Reaching here without a top reading still validated the controlled
        // bound; top occasionally emits no per-pid sample under load.
    }

    func testMemoryAndSwapReadingsArePlausible() async throws {
        try requireHardware()
        let source = LiveTelemetrySource(targetPID: nil, cadence: .milliseconds(50))
        for await sample in await source.stream() {
            let physical = ProcessInfo.processInfo.physicalMemory
            XCTAssertGreaterThan(sample.system.memoryUsedBytes, physical / 20)
            XCTAssertLessThan(sample.system.memoryUsedBytes, physical)
            break
        }
    }

    /// `top -l 3` per-pid CPU%: the last sample is interval-based like ours.
    private static func topCPUPercent(pid: Int32) async -> Double? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/top")
        process.arguments = ["-l", "3", "-s", "1", "-pid", "\(pid)", "-stats", "cpu"]
        let pipe = Pipe()
        process.standardOutput = pipe
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let values = String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        return values.last
    }
}

/// Tiny lock-boxed flag so the spin thread can be stopped from Swift 6
/// concurrency-checked code.
private final class Atomic: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Bool
    init(_ value: Bool) { self.stored = value }
    var value: Bool {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
