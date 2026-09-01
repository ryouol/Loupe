import Foundation

/// Ordered so annotation rules can express "state increased".
public enum ThermalState: String, Codable, Sendable, CaseIterable, Comparable {
    case nominal
    case fair
    case serious
    case critical

    public static func < (lhs: ThermalState, rhs: ThermalState) -> Bool {
        lhs.severity < rhs.severity
    }

    private var severity: Int {
        switch self {
        case .nominal: return 0
        case .fair: return 1
        case .serious: return 2
        case .critical: return 3
        }
    }
}

/// Machine-wide signals — a different type from `ProcessSample` because
/// mixing the two families produces analysis that looks meaningful and isn't.
public struct SystemWideSample: Codable, Sendable, Equatable {
    public let ts: UInt64
    public let thermalState: ThermalState
    public let memoryUsedBytes: UInt64
    public let memoryFreeBytes: UInt64
    public let swapUsedBytes: UInt64
    /// nil = not sampled on this machine (IOReport, M1.2); the UI hides the
    /// chart rather than drawing zeros.
    public let gpuBusyPercent: Double?
    public let gpuPowerMilliwatts: Double?
    public let anePowerMilliwatts: Double?
    public let packagePowerMilliwatts: Double?

    public init(
        ts: UInt64,
        thermalState: ThermalState,
        memoryUsedBytes: UInt64,
        memoryFreeBytes: UInt64,
        swapUsedBytes: UInt64,
        gpuBusyPercent: Double? = nil,
        gpuPowerMilliwatts: Double? = nil,
        anePowerMilliwatts: Double? = nil,
        packagePowerMilliwatts: Double? = nil
    ) {
        self.ts = ts
        self.thermalState = thermalState
        self.memoryUsedBytes = memoryUsedBytes
        self.memoryFreeBytes = memoryFreeBytes
        self.swapUsedBytes = swapUsedBytes
        self.gpuBusyPercent = gpuBusyPercent
        self.gpuPowerMilliwatts = gpuPowerMilliwatts
        self.anePowerMilliwatts = anePowerMilliwatts
        self.packagePowerMilliwatts = packagePowerMilliwatts
    }
}

/// Per-process signals for the observed inference process.
public struct ProcessSample: Codable, Sendable, Equatable {
    public let ts: UInt64
    public let pid: Int32
    /// rusage delta over wall time (100 ≈ one core); first sample is 0
    /// because a single cumulative reading is meaningless.
    public let cpuPercent: Double
    public let rssBytes: UInt64

    public init(ts: UInt64, pid: Int32, cpuPercent: Double, rssBytes: UInt64) {
        self.ts = ts
        self.pid = pid
        self.cpuPercent = cpuPercent
        self.rssBytes = rssBytes
    }
}

/// One telemetry row: both families aligned in time, never merged.
public struct SystemSample: Codable, Sendable, Equatable {
    public let system: SystemWideSample
    public let process: ProcessSample?

    public init(system: SystemWideSample, process: ProcessSample?) {
        self.system = system
        self.process = process
    }
}

/// Semantic validation shared by replay, persistence, and XPC decoding.
/// Codable proves the shape and numeric representation; these checks prove
/// the values can describe a real sample and are safe to graph.
public enum SystemSampleValidation {
    public static func accepts(_ sample: SystemSample) -> Bool {
        let system = sample.system
        guard validPercentage(system.gpuBusyPercent),
            validNonnegative(system.gpuPowerMilliwatts),
            validNonnegative(system.anePowerMilliwatts),
            validNonnegative(system.packagePowerMilliwatts)
        else { return false }
        guard let process = sample.process else { return true }
        return process.ts == system.ts && process.pid > 0
            && process.cpuPercent.isFinite && process.cpuPercent >= 0
    }

    private static func validPercentage(_ value: Double?) -> Bool {
        value.map { $0.isFinite && (0...100).contains($0) } ?? true
    }

    private static func validNonnegative(_ value: Double?) -> Bool {
        value.map { $0.isFinite && $0 >= 0 } ?? true
    }
}

/// Strict JSON boundary for telemetry crossing XPC or replay files. Swift's
/// synthesized Codable implementation ignores unknown keys by default; that
/// is useful for app models but unsafe at a wire boundary because hidden text
/// or future semantics could pass through without being shown to the user.
public enum SystemSampleWireDecoder {
    public static let maxLineBytes = 65_536

    public static func decode(_ data: Data) -> SystemSample? {
        guard data.count <= maxLineBytes,
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            Set(root.keys).isSubset(of: ["system", "process"]),
            let system = root["system"] as? [String: Any],
            Set(system.keys).isSubset(of: [
                "ts", "thermalState", "memoryUsedBytes", "memoryFreeBytes", "swapUsedBytes",
                "gpuBusyPercent", "gpuPowerMilliwatts", "anePowerMilliwatts",
                "packagePowerMilliwatts",
            ])
        else { return nil }
        if let processValue = root["process"], !(processValue is NSNull) {
            guard let process = processValue as? [String: Any],
                Set(process.keys).isSubset(of: ["ts", "pid", "cpuPercent", "rssBytes"])
            else { return nil }
        }
        guard let sample = try? JSONDecoder().decode(SystemSample.self, from: data),
            SystemSampleValidation.accepts(sample)
        else { return nil }
        return sample
    }
}
