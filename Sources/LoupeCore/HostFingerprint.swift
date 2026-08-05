/// Identifies the machine a session ran on — two runs are only comparable
/// when their fingerprints match. Pure data; the sysctl reader lives in
/// LoupeSampler because LoupeCore does no I/O.
public struct HostFingerprint: Codable, Sendable, Equatable {
    public let chip: String
    public let model: String
    public let performanceCores: Int
    public let efficiencyCores: Int
    public let memoryBytes: UInt64
    public let osVersion: String
    public let osBuild: String

    public init(
        chip: String,
        model: String,
        performanceCores: Int,
        efficiencyCores: Int,
        memoryBytes: UInt64,
        osVersion: String,
        osBuild: String
    ) {
        self.chip = chip
        self.model = model
        self.performanceCores = performanceCores
        self.efficiencyCores = efficiencyCores
        self.memoryBytes = memoryBytes
        self.osVersion = osVersion
        self.osBuild = osBuild
    }
}
