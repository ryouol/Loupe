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

/// Everything readable without root: thermal, memory, swap, per-PID CPU/RSS.
/// GPU/power fields stay nil here forever — IOReport lands in M1.2.
public actor LiveTelemetrySource: TelemetrySource {
    private let targetPID: Int32?
    private let cadence: Duration
    private let timebase: Timebase

    public init(
        targetPID: Int32?,
        cadence: Duration = Sampling.defaultCadence,
        timebase: Timebase = .live()
    ) {
        self.targetPID = targetPID
        self.cadence = cadence
        self.timebase = timebase
    }

    public func stream() -> AsyncStream<SystemSample> {
        let pid = targetPID
        let cadence = cadence
        let timebase = timebase
        return AsyncStream { continuation in
            let task = Task {
                var tracker = CPUDeltaTracker()
                while !Task.isCancelled {
                    continuation.yield(
                        Self.takeSample(pid: pid, timebase: timebase, tracker: &tracker))
                    try? await Task.sleep(for: cadence)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func takeSample(
        pid: Int32?, timebase: Timebase, tracker: inout CPUDeltaTracker
    ) -> SystemSample {
        let now = timebase.nowNanoseconds()
        let memory = memorySnapshot()
        let system = SystemWideSample(
            ts: now,
            thermalState: ThermalState(platform: ProcessInfo.processInfo.thermalState),
            memoryUsedBytes: memory.used,
            memoryFreeBytes: memory.free,
            swapUsedBytes: swapUsedBytes())
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
