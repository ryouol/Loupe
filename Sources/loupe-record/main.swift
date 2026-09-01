import Darwin
import Foundation
import LoupeCore
import LoupeTelemetry

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
    case "--pid":
        guard let value = arguments.next(), let parsed = Int32(value), parsed > 0 else {
            fail("--pid requires a positive 32-bit process id")
        }
        targetPID = parsed
    case "--duration":
        guard let value = arguments.next(), let parsed = Double(value) else {
            fail("--duration requires a number")
        }
        durationSeconds = parsed
    case "--hz":
        guard let value = arguments.next(), let parsed = Double(value) else {
            fail("--hz requires a number")
        }
        hz = parsed
    default: fail("usage: loupe-record --out <file> [--pid <pid>] [--duration <s>] [--hz <n>]")
    }
}

guard let outPath, !outPath.isEmpty else { fail("--out is required") }
guard hz.isFinite, (0.1...100).contains(hz),
    durationSeconds.isFinite, (0.1...3_600).contains(durationSeconds),
    durationSeconds * hz <= 100_000
else {
    fail("--hz/--duration must produce at most 100,000 rows within one hour")
}
if let targetPID {
    var processInfo = proc_bsdinfo()
    let expected = Int32(MemoryLayout<proc_bsdinfo>.size)
    let actual = withUnsafeMutablePointer(to: &processInfo) { pointer in
        proc_pidinfo(targetPID, PROC_PIDTBSDINFO, 0, pointer, expected)
    }
    guard actual == expected, processInfo.pbi_uid == geteuid() else {
        fail("--pid must name a process owned by the current user")
    }
}

let descriptor = open(
    outPath, O_WRONLY | O_CREAT | O_NOFOLLOW | O_CLOEXEC,
    S_IRUSR | S_IWUSR)
guard descriptor >= 0 else {
    fail("cannot open \(outPath) for writing")
}
var outputMetadata = stat()
guard fstat(descriptor, &outputMetadata) == 0,
    outputMetadata.st_mode & S_IFMT == S_IFREG,
    outputMetadata.st_uid == geteuid(), outputMetadata.st_nlink == 1,
    fchmod(descriptor, S_IRUSR | S_IWUSR) == 0,
    ftruncate(descriptor, 0) == 0
else {
    close(descriptor)
    fail("output must be one owner-controlled regular file")
}
let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)

let encoder = JSONEncoder.deterministic()

let source = LiveTelemetrySource(
    targetPID: targetPID,
    cadence: Sampling.clampedCadence(intervalMs: Int(1_000.0 / hz)),
    makePowerReader: { IOReportPowerReader() })
let start = Timebase.live().nowNanoseconds()
let durationNs = UInt64(durationSeconds * 1_000_000_000)
let deadlineResult = start.addingReportingOverflow(durationNs)
guard !deadlineResult.overflow else { fail("recording deadline exceeds the local clock") }
let deadline = deadlineResult.partialValue
var written = 0
var consecutiveProcessMisses = 0

for await sample in await source.stream() {
    if let line = try? encoder.encode(sample) {
        do {
            try handle.write(contentsOf: line)
            try handle.write(contentsOf: Data([UInt8(ascii: "\n")]))
            written += 1
        } catch {
            try? handle.close()
            fail("telemetry output failed")
        }
    }
    if sample.system.ts >= deadline { break }
    // Exit with the observed process so the file never ends mid-line.
    if targetPID != nil {
        consecutiveProcessMisses = sample.process == nil ? consecutiveProcessMisses + 1 : 0
        if consecutiveProcessMisses >= 3 { break }
    }
}

do {
    try handle.synchronize()
    try handle.close()
} catch {
    fail("telemetry output could not be finalized")
}
print("loupe-record: wrote \(written) samples to \(outPath)")
