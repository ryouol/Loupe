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
