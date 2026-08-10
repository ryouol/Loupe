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

var specPath: String?
var outPath: String?
var pythonPath = ".venv/bin/python"

var arguments = CommandLine.arguments.dropFirst().makeIterator()
while let argument = arguments.next() {
    switch argument {
    case "--spec": specPath = arguments.next()
    case "--out": outPath = arguments.next()
    case "--python": pythonPath = arguments.next() ?? pythonPath
    default: fail("usage: loupe-bench --spec <spec.yaml> --out <report.json> [--python <path>]")
    }
}
guard let specPath, let outPath else { fail("--spec and --out are required") }

let spec: BenchmarkSpec
do {
    spec = try BenchmarkSpec.fromYAML(try String(contentsOfFile: specPath, encoding: .utf8))
} catch {
    fail("cannot parse spec: \(error)")
}
guard spec.runtime == "mlx" else {
    fail("only the mlx runtime is wired yet (llama.cpp arrives with M3)")
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
    ]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw NSError(
            domain: "loupe-bench", code: Int(process.terminationStatus),
            userInfo: [NSLocalizedDescriptionKey: "bench run exited nonzero"])
    }

    let decoder = EventLineDecoder()
    let blob = try Data(contentsOf: URL(fileURLWithPath: eventsPath))
    return blob.split(separator: UInt8(ascii: "\n")).compactMap {
        try? decoder.decode(line: Data($0)).get()
    }
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
                log("cooldown timed out before context \(context) run \(runIndex); proceeding")
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

    let report = BenchmarkAssembler.report(
        spec: spec,
        host: HostInfo.fingerprint(),
        createdAtNs: Timebase.live().nowNanoseconds(),
        measuredRunsByContext: measured)
    try BenchmarkAssembler.encode(report).write(to: URL(fileURLWithPath: outPath))
    log("report written to \(outPath)")
} catch {
    fail("benchmark failed: \(error)")
}
