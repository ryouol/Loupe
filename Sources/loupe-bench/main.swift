import CryptoKit
import Darwin
import Foundation
import LoupeBench
import LoupeCore
import LoupeSampler

// Benchmark orchestrator: spec in, report out. Each measured run is one
// python process (cold request state, warm OS caches), gated on thermal
// nominal so run N doesn't measure run N-1's heat.

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

func log(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

func writeOwnerOnlyAtomically(_ data: Data, to destination: URL) throws {
    let directory = destination.deletingLastPathComponent()
    let temporary = directory.appendingPathComponent(
        ".\(UUID().uuidString.lowercased()).report.tmp")
    var descriptor = open(
        temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
        S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    defer {
        if descriptor >= 0 { close(descriptor) }
        unlink(temporary.path)
    }
    guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    try data.withUnsafeBytes { raw in
        guard let base = raw.baseAddress else { return }
        var offset = 0
        while offset < raw.count {
            let written = Darwin.write(
                descriptor, base.advanced(by: offset), raw.count - offset)
            if written > 0 {
                offset += written
            } else if written < 0, errno == EINTR {
                continue
            } else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
    }
    guard fsync(descriptor) == 0, close(descriptor) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    descriptor = -1
    guard rename(temporary.path, destination.path) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    let directoryDescriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard directoryDescriptor >= 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    defer { close(directoryDescriptor) }
    guard fsync(directoryDescriptor) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}

var specPath: String?
var outPath: String?
var pythonPath = ".venv/bin/python"
var runtimeVersion: String?
var modelRevision: String?
var modelSHA256: String?
var dependencyLockPath = "adapters/loupe-mlx/uv.lock"

var arguments = CommandLine.arguments.dropFirst().makeIterator()
while let argument = arguments.next() {
    switch argument {
    case "--spec": specPath = arguments.next()
    case "--out": outPath = arguments.next()
    case "--python": pythonPath = arguments.next() ?? pythonPath
    case "--runtime-version": runtimeVersion = arguments.next()
    case "--model-revision": modelRevision = arguments.next()
    case "--model-sha256": modelSHA256 = arguments.next()
    case "--dependency-lock": dependencyLockPath = arguments.next() ?? dependencyLockPath
    default:
        fail(
            "usage: loupe-bench --spec <spec.yaml> --out <report.json> "
                + "--runtime-version <version> --model-revision <revision> "
                + "--model-sha256 <sha256> [--dependency-lock <path>] [--python <path>]")
    }
}
guard let specPath, let outPath else { fail("--spec and --out are required") }
guard let runtimeVersion, let modelRevision, let modelSHA256,
    !runtimeVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
    runtimeVersion.utf8.count <= 1_024,
    runtimeVersion.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != "unknown",
    !modelRevision.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
    modelRevision.utf8.count <= 1_024,
    modelRevision.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != "unknown",
    modelSHA256.count == 64,
    modelSHA256.allSatisfy({ $0.isASCII && $0.isHexDigit }),
    Set(modelSHA256.lowercased()).count > 1
else {
    fail("complete runtime/model revisions and a non-placeholder model SHA-256 are required")
}
let dependencyLockData: Data
do {
    dependencyLockData = try ReplayResourceLimits.read(
        URL(fileURLWithPath: dependencyLockPath), maximumBytes: 64 * 1_024 * 1_024)
} catch {
    fail("cannot read dependency lock at \(dependencyLockPath): \(error)")
}
let dependencyLockSHA256 = SHA256.hash(data: dependencyLockData)
    .map { String(format: "%02x", $0) }.joined()

let spec: BenchmarkSpec
do {
    let specData = try ReplayResourceLimits.read(
        URL(fileURLWithPath: specPath), maximumBytes: 1_048_576)
    guard let text = String(data: specData, encoding: .utf8) else {
        throw CocoaError(.fileReadInapplicableStringEncoding)
    }
    spec = try BenchmarkSpec.fromYAML(text)
} catch {
    fail("cannot parse spec: \(error)")
}
guard spec.validationFailures.isEmpty else {
    fail("invalid benchmark spec: \(spec.validationFailures.joined(separator: ", "))")
}
guard spec.runtime == "mlx" else {
    fail("the benchmark harness currently supports the mlx runtime only")
}

@MainActor
func runOnce(contextTokens: Int, seed: UInt64, runIndex: Int) throws -> [EventEnvelope] {
    let eventsPath = FileManager.default.temporaryDirectory
        .appendingPathComponent("loupe-bench-\(UUID().uuidString).ndjson").path
    defer { try? FileManager.default.removeItem(atPath: eventsPath) }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: pythonPath)
    process.arguments = [
        "-m", "loupe_mlx.bench",
        "--model", spec.model,
        "--out", eventsPath,
        "--context-tokens", String(contextTokens),
        "--max-tokens", String(spec.outputTokens),
        "--seed", String(seed),
        "--run-id", "r-bench-c\(contextTokens)-\(runIndex)",
        "--prompt-base", spec.promptCorpus.joined(separator: " "),
    ]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw NSError(
            domain: "loupe-bench", code: Int(process.terminationStatus),
            userInfo: [NSLocalizedDescriptionKey: "bench run exited nonzero"])
    }

    let blob = try ReplayResourceLimits.read(
        URL(fileURLWithPath: eventsPath), maximumBytes: ReplayResourceLimits.maxEventFileBytes)
    let (envelopes, drops) = EventLineDecoder().decodeLines(blob)
    if drops.total > 0 {
        throw NSError(
            domain: "loupe-bench", code: 2,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "run output contained \(drops.total) undecodable event lines"
            ])
    }
    var sequence = EventStreamValidator()
    guard envelopes.allSatisfy({ sequence.accepts($0) }), sequence.hasStartedSession,
        !sequence.hasOpenRequests, sequence.hasTerminalSummary
    else {
        throw NSError(
            domain: "loupe-bench", code: 6,
            userInfo: [NSLocalizedDescriptionKey: "run output has an invalid event sequence"])
    }
    return envelopes
}

@MainActor
func installedAdapterVersion() throws -> String {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: pythonPath)
    process.arguments = ["-c", "import loupe_mlx; print(loupe_mlx.__version__)"]
    process.standardOutput = output
    process.standardError = FileHandle.standardError
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw NSError(
            domain: "loupe-bench", code: Int(process.terminationStatus),
            userInfo: [NSLocalizedDescriptionKey: "cannot read installed adapter version"])
    }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    let version = String(decoding: data.prefix(128), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !version.isEmpty, version.utf8.count <= 1_024,
        version.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != "unknown"
    else {
        throw NSError(
            domain: "loupe-bench", code: 3,
            userInfo: [NSLocalizedDescriptionKey: "installed adapter version is empty"])
    }
    return version
}

do {
    var measured: [Int: [[EventEnvelope]]] = [:]
    for context in spec.contexts {
        var runs: [[EventEnvelope]] = []
        let total = spec.warmup + spec.repeats
        for runIndex in 0..<total {
            let outcome = await CooldownGate.waitForNominal(
                states: ThermalStateMonitor.states(),
                timeout: .seconds(spec.cooldownTimeoutSeconds))
            if outcome == .timedOut {
                throw NSError(
                    domain: "loupe-bench", code: 4,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "cooldown timed out before context \(context) run \(runIndex)"
                    ])
            }
            let events = try runOnce(
                contextTokens: context, seed: spec.seed, runIndex: runIndex)
            let isWarmup = runIndex < spec.warmup
            log(
                "context \(context) run \(runIndex + 1)/\(total)"
                    + (isWarmup ? " (warmup, discarded)" : ""))
            if !isWarmup {
                runs.append(events)
            }
        }
        measured[context] = runs
    }

    let adapterVersion = try installedAdapterVersion()
    let report = BenchmarkAssembler.report(
        spec: spec,
        host: HostInfo.fingerprint(),
        createdAtNs: Timebase.live().nowNanoseconds(),
        provenance: BenchmarkProvenance(
            toolVersion: Loupe.version,
            adapterVersion: adapterVersion,
            runtimeVersion: runtimeVersion,
            modelRevision: modelRevision,
            modelArtifactSHA256: modelSHA256.lowercased(),
            dependencyLockSHA256: dependencyLockSHA256),
        measuredRunsByContext: measured)
    guard report.validationFailures.isEmpty else {
        throw NSError(
            domain: "loupe-bench", code: 5,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "assembled report is invalid: \(report.validationFailures.joined(separator: ", "))"
            ])
    }
    try writeOwnerOnlyAtomically(
        BenchmarkAssembler.encode(report), to: URL(fileURLWithPath: outPath))
    log("report written to \(outPath)")
} catch {
    fail("benchmark failed: \(error)")
}
