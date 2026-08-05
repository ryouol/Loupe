/// Thermal pressure, ordered so annotation rules can express "state
/// increased" without caring about the raw platform values.
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

/// Machine-wide signals. Deliberately a different type from `ProcessSample`:
/// mixing the two families (e.g. comparing package power to one process's
/// CPU%) produces analysis that looks meaningful and isn't.
public struct SystemWideSample: Codable, Sendable, Equatable {
    /// Continuous-clock nanoseconds on the sampling machine.
    public let ts: UInt64
    public let thermalState: ThermalState
    public let memoryUsedBytes: UInt64
    public let memoryFreeBytes: UInt64
    public let swapUsedBytes: UInt64
    /// GPU/power channels come from IOReport (M1.2). nil means "not sampled
    /// on this machine" — the UI hides those charts instead of drawing zeros.
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
    /// Delta between two rusage reads over wall time; 100 ≈ one saturated
    /// core. The first sample of a stream is always 0 — a single cumulative
    /// reading is meaningless.
    public let cpuPercent: Double
    public let rssBytes: UInt64

    public init(ts: UInt64, pid: Int32, cpuPercent: Double, rssBytes: UInt64) {
        self.ts = ts
        self.pid = pid
        self.cpuPercent = cpuPercent
        self.rssBytes = rssBytes
    }
}

/// One row of telemetry: the two families aligned in time but never merged.
public struct SystemSample: Codable, Sendable, Equatable {
    public let system: SystemWideSample
    /// nil when no process is being observed or the target exited.
    public let process: ProcessSample?

    public init(system: SystemWideSample, process: ProcessSample?) {
        self.system = system
        self.process = process
    }
}
