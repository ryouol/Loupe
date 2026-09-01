import Foundation

/// One reading of the machine-wide power/GPU channels. Any field may be nil:
/// channel names differ across chip generations and some require the root
/// daemon context — absence must degrade, never zero-fill.
public struct PowerReading: Sendable, Equatable {
    public var gpuBusyPercent: Double?
    public var gpuPowerMilliwatts: Double?
    public var anePowerMilliwatts: Double?
    public var packagePowerMilliwatts: Double?

    public init(
        gpuBusyPercent: Double? = nil,
        gpuPowerMilliwatts: Double? = nil,
        anePowerMilliwatts: Double? = nil,
        packagePowerMilliwatts: Double? = nil
    ) {
        self.gpuBusyPercent = gpuBusyPercent
        self.gpuPowerMilliwatts = gpuPowerMilliwatts
        self.anePowerMilliwatts = anePowerMilliwatts
        self.packagePowerMilliwatts = packagePowerMilliwatts
    }
}

/// Stateful reader (deltas between calls). Created and used inside a single
/// sampling task, so it needs no Sendable ceremony.
public protocol PowerChannelReading: AnyObject {
    /// First call establishes the baseline and returns an empty reading.
    func sample() -> PowerReading
}

/// The name-resolution rules, kept pure so every chip-generation variant is
/// unit-testable without hardware. IOReport channel keys are never indexed
/// blindly — resolve by name, tolerate absence.
enum IOReportChannelLogic {
    struct Selection: Equatable {
        var gpuEnergy: String?
        var aneEnergy: String?
        var cpuEnergy: String?
        var gpuPerformanceStates: String?
    }

    static func resolve(
        energyChannels: [String], gpuStatsChannels: [String]
    ) -> Selection {
        func firstEnergy(prefix: String) -> String? {
            energyChannels.first { $0 == "\(prefix) Energy" }
                ?? energyChannels.first {
                    $0.hasPrefix(prefix) && $0.localizedCaseInsensitiveContains("energy")
                }
        }
        return Selection(
            gpuEnergy: firstEnergy(prefix: "GPU"),
            aneEnergy: firstEnergy(prefix: "ANE"),
            cpuEnergy: firstEnergy(prefix: "CPU"),
            gpuPerformanceStates: gpuStatsChannels.first { $0 == "GPUPH" }
                ?? gpuStatsChannels.first { $0.contains("Performance State") })
    }

    /// Energy channels report in generation-dependent units; unknown units
    /// degrade to nil rather than silently mis-scaling.
    static func millijoules(_ value: Int64, unitLabel: String) -> Double? {
        guard value >= 0 else { return nil }
        switch unitLabel.trimmingCharacters(in: .whitespaces) {
        case "mJ": return Double(value)
        case "uJ", "µJ": return Double(value) / 1_000
        case "nJ": return Double(value) / 1_000_000
        default: return nil
        }
    }

    static func milliwatts(energyMillijoules: Double, intervalNs: UInt64) -> Double? {
        guard intervalNs > 0, energyMillijoules.isFinite, energyMillijoules >= 0 else {
            return nil
        }
        let value = energyMillijoules / (Double(intervalNs) / 1_000_000_000)
        return value.isFinite ? value : nil
    }

    /// Busy% from performance-state residency deltas: everything that isn't
    /// an off/idle state counts as busy.
    static func busyPercent(states: [(name: String, residency: Int64)]) -> Double? {
        let total = states.reduce(0.0) { $0 + Double(max(0, $1.residency)) }
        guard total > 0 else { return nil }
        let idle = states.filter { isIdleState($0.name) }
            .reduce(0.0) { $0 + Double(max(0, $1.residency)) }
        return 100.0 * (total - idle) / total
    }

    private static func isIdleState(_ name: String) -> Bool {
        let upper = name.uppercased()
        return upper == "OFF" || upper == "IDLE" || upper.hasPrefix("IDLE")
    }
}
