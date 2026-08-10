import Foundation
import LoupeCore
import LoupeSampler

// Fixture recorder: unprivileged telemetry to SystemSample NDJSON. Four
// hand-parsed flags don't warrant an argument-parser dependency.

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

var outPath: String?
var targetPID: Int32?
var durationSeconds = 60.0
var hz = Sampling.defaultHz

var arguments = CommandLine.arguments.dropFirst().makeIterator()
while let argument = arguments.next() {
    switch argument {
    case "--out": outPath = arguments.next()
    case "--pid": targetPID = arguments.next().flatMap { Int32($0) }
    case "--duration": durationSeconds = arguments.next().flatMap(Double.init) ?? durationSeconds
    case "--hz": hz = arguments.next().flatMap(Double.init) ?? hz
    default: fail("usage: loupe-record --out <file> [--pid <pid>] [--duration <s>] [--hz <n>]")
    }
}

guard let outPath else { fail("--out is required") }
guard hz > 0, hz <= 1_000, durationSeconds > 0 else { fail("implausible --hz or --duration") }

guard FileManager.default.createFile(atPath: outPath, contents: nil),
    let handle = FileHandle(forWritingAtPath: outPath)
else {
    fail("cannot open \(outPath) for writing")
}

let encoder = JSONEncoder.deterministic()

let source = LiveTelemetrySource(
    targetPID: targetPID,
    cadence: .milliseconds(Int(1000.0 / hz)),
    makePowerReader: { IOReportPowerReader() })
let deadline = Timebase.live().nowNanoseconds() + UInt64(durationSeconds * 1_000_000_000)
var written = 0
var consecutiveProcessMisses = 0

for await sample in await source.stream() {
    if let line = try? encoder.encode(sample) {
        handle.write(line)
        handle.write(Data([UInt8(ascii: "\n")]))
        written += 1
    }
    if sample.system.ts >= deadline { break }
    // Exit with the observed process so the file never ends mid-line.
    if targetPID != nil {
        consecutiveProcessMisses = sample.process == nil ? consecutiveProcessMisses + 1 : 0
        if consecutiveProcessMisses >= 3 { break }
    }
}

try handle.close()
print("loupe-record: wrote \(written) samples to \(outPath)")
