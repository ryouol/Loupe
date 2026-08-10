import Darwin
import Foundation
import LoupeCore

/// CPU% is a delta between cumulative rusage reads over wall time; the
/// tracker owns the previous reading.
public struct CPUDeltaTracker: Sendable {
    private var previous: (cpuNs: UInt64, wallNs: UInt64)?

    public init() {}

    public mutating func percent(cpuNs: UInt64, wallNs: UInt64) -> Double {
        defer { previous = (cpuNs, wallNs) }
        guard let previous, wallNs > previous.wallNs, cpuNs >= previous.cpuNs else {
            return 0
        }
        return Double(cpuNs - previous.cpuNs) / Double(wallNs - previous.wallNs) * 100
    }
}

extension ThermalState {
    public init(platform state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .critical
        }
    }
}

/// Thermal, memory, swap, and per-PID CPU/RSS — all readable without root.
/// GPU/power channels come from the injected IOReport reader; without one
/// those fields stay nil and the UI hides their charts.
public actor LiveTelemetrySource: TelemetrySource {
    private let targetPID: Int32?
    private let cadence: Duration
    private let timebase: Timebase
    private let makePowerReader: @Sendable () -> (any PowerChannelReading)?

    /// The power reader is a factory because the reader itself is stateful
    /// and non-Sendable — it is created and lives entirely inside the
    /// sampling task.
    public init(
        targetPID: Int32?,
        cadence: Duration = Sampling.defaultCadence,
        timebase: Timebase = .live(),
        makePowerReader: @escaping @Sendable () -> (any PowerChannelReading)? = { nil }
    ) {
        self.targetPID = targetPID
        self.cadence = cadence
        self.timebase = timebase
        self.makePowerReader = makePowerReader
    }

    public func stream() -> AsyncStream<SystemSample> {
        let pid = targetPID
        let cadence = cadence
        let timebase = timebase
        let makePowerReader = makePowerReader
        return AsyncStream { continuation in
            let task = Task {
                var tracker = CPUDeltaTracker()
                let powerReader = makePowerReader()
                while !Task.isCancelled {
                    let power = powerReader?.sample() ?? PowerReading()
                    continuation.yield(
                        Self.takeSample(
                            pid: pid, timebase: timebase, tracker: &tracker, power: power))
                    try? await Task.sleep(for: cadence)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func takeSample(
        pid: Int32?, timebase: Timebase, tracker: inout CPUDeltaTracker,
        power: PowerReading = PowerReading()
    ) -> SystemSample {
        let now = timebase.nowNanoseconds()
        let memory = memorySnapshot()
        let system = SystemWideSample(
            ts: now,
            thermalState: ThermalState(platform: ProcessInfo.processInfo.thermalState),
            memoryUsedBytes: memory.used,
            memoryFreeBytes: memory.free,
            swapUsedBytes: swapUsedBytes(),
            gpuBusyPercent: power.gpuBusyPercent,
            gpuPowerMilliwatts: power.gpuPowerMilliwatts,
            anePowerMilliwatts: power.anePowerMilliwatts,
            packagePowerMilliwatts: power.packagePowerMilliwatts)
        let process = pid.flatMap {
            processSnapshot(pid: $0, timebase: timebase, tracker: &tracker, nowNs: now)
        }
        return SystemSample(system: system, process: process)
    }

    private static func memorySnapshot() -> (used: UInt64, free: UInt64) {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return (0, 0) }
        let pageSize = UInt64(getpagesize())
        let used =
            (UInt64(stats.active_count) + UInt64(stats.wire_count)
                + UInt64(stats.compressor_page_count)) * pageSize
        return (used, UInt64(stats.free_count) * pageSize)
    }

    private static func swapUsedBytes() -> UInt64 {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return 0 }
        return usage.xsu_used
    }

    /// nil when the process is gone; the stream keeps sampling the system.
    private static func processSnapshot(
        pid: Int32, timebase: Timebase, tracker: inout CPUDeltaTracker, nowNs: UInt64
    ) -> ProcessSample? {
        var info = rusage_info_current()
        let result = withUnsafeMutablePointer(to: &info) { pointer -> Int32 in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { raw in
                proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, raw)
            }
        }
        guard result == 0 else { return nil }
        // ri_*_time are mach ticks on the same timebase as the wall clock.
        let cpuNs = timebase.nanoseconds(fromTicks: info.ri_user_time &+ info.ri_system_time)
        return ProcessSample(
            ts: nowNs,
            pid: pid,
            cpuPercent: tracker.percent(cpuNs: cpuNs, wallNs: nowNs),
            rssBytes: info.ri_resident_size)
    }
}
