import Foundation
import LoupeCore
import LoupeSampler

// Minimal fixture recorder: samples unprivileged telemetry at a fixed cadence
// and writes SystemSample NDJSON. Deliberately hand-parsed flags — this tool
// has exactly four and doesn't warrant a dependency.

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

var outPath: String?
var targetPID: Int32?
var durationSeconds = 60.0
var hz = 10.0

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

let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

let source = UnprivilegedTelemetrySource(
    targetPID: targetPID,
    cadence: .milliseconds(Int(1000.0 / hz)))
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
    // Following a target process: once it exits, finish cleanly instead of
    // waiting out the deadline — the file must never end mid-line via kill.
    if targetPID != nil {
        consecutiveProcessMisses = sample.process == nil ? consecutiveProcessMisses + 1 : 0
        if consecutiveProcessMisses >= 3 { break }
    }
}

try handle.close()
print("loupe-record: wrote \(written) samples to \(outPath)")
