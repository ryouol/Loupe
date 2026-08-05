import Darwin
import Foundation
import LoupeCore

/// Reads the host fingerprint via sysctl. Missing keys degrade to sentinel
/// values rather than failing — IOReport taught us not to index blindly, and
/// core-count key names are the same kind of chip-generation-dependent.
public enum HostInfo {
    public static func fingerprint() -> HostFingerprint {
        HostFingerprint(
            chip: string("machdep.cpu.brand_string") ?? "unknown",
            model: string("hw.model") ?? "unknown",
            performanceCores: int("hw.perflevel0.physicalcpu") ?? 0,
            efficiencyCores: int("hw.perflevel1.physicalcpu") ?? 0,
            memoryBytes: uint64("hw.memsize") ?? 0,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            osBuild: string("kern.osversion") ?? "unknown")
    }

    private static func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return buffer.withUnsafeBufferPointer { pointer in
            pointer.baseAddress.flatMap { String(validatingCString: $0) }
        }
    }

    private static func int(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    }

    private static func uint64(_ name: String) -> UInt64? {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }
}
