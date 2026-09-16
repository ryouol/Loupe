import CryptoKit
import Darwin
import Foundation
import LoupeCore

// Headless replay uses the same decoder and request metrics as the native app.
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

func readBounded(_ path: String) throws -> Data {
    let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw CocoaError(.fileReadNoSuchFile) }
    let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    defer { try? file.close() }
    var info = stat()
    let limit = 32 * 1_024 * 1_024
    guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
        info.st_size <= limit
    else { throw CocoaError(.fileReadTooLarge) }
    let data = try file.read(upToCount: limit + 1) ?? Data()
    guard data.count <= limit else { throw CocoaError(.fileReadTooLarge) }
    return data
}

struct Report: Encodable {
    let schemaVersion = 1
    let eventSHA256: String
    let telemetrySHA256: String
    let eventCount: Int
    let sampleCount: Int
    let eventParserDrops: Int
    let telemetryParserDrops: Int
    let requests: [RequestMetrics]
    let finishReasons: [String: Int]
    let thermalStates: [String]
    let acquisitionNote =
        "Parser drops are not acquisition loss counts; retain transport summaries."
}

var eventsPath: String?
var systemPath: String?
var outputPath: String?
var args = CommandLine.arguments.dropFirst().makeIterator()
while let arg = args.next() {
    switch arg {
    case "--events": eventsPath = args.next()
    case "--system": systemPath = args.next()
    case "--out": outputPath = args.next()
    default: fail("usage: loupe-report --events FILE --system FILE --out NEW_DIRECTORY")
    }
}
guard let eventsPath, let systemPath, let outputPath else {
    fail("--events, --system and --out are required")
}
do {
    let eventData = try readBounded(eventsPath)
    let systemData = try readBounded(systemPath)
    let decoded = EventLineDecoder().decodeLines(eventData)
    var sampleDrops = 0
    var samples: [SystemSample] = []
    for line in systemData.split(separator: 10) {
        if line.count <= EventLineDecoder.maxLineBytes,
            let sample = try? JSONDecoder().decode(SystemSample.self, from: Data(line))
        {
            samples.append(sample)
        } else {
            sampleDrops += 1
        }
    }
    var reasons: [String: Int] = [:]
    for event in decoded.envelopes {
        if case .requestEnd(let end) = event.payload {
            reasons[end.finishReason, default: 0] += 1
        }
    }
    let requests = SessionMetrics.perRequest(events: decoded.envelopes)
    let report = Report(
        eventSHA256: SHA256.hash(data: eventData).map { String(format: "%02x", $0) }.joined(),
        telemetrySHA256: SHA256.hash(data: systemData).map { String(format: "%02x", $0) }.joined(),
        eventCount: decoded.envelopes.count, sampleCount: samples.count,
        eventParserDrops: decoded.drops.total, telemetryParserDrops: sampleDrops,
        requests: requests, finishReasons: reasons,
        thermalStates: Array(Set(samples.map { $0.system.thermalState.rawValue })).sorted())
    guard mkdir(outputPath, S_IRWXU) == 0 else {
        fail("output must be a new directory in an existing parent")
    }
    let output = URL(fileURLWithPath: outputPath)
    try JSONEncoder.deterministic().encode(report).write(
        to: output.appendingPathComponent("report.json"))
    // IDs can be untrusted spreadsheet formula text, so use the shared encoder.
    var csv = ["request_id,prompt_tokens,output_tokens,ttft_ms,decode_tokens_per_second"]
    for request in requests {
        csv.append(
            [
                request.requestId, String(request.promptTokens), String(request.outputTokens),
                String(request.ttftMs), String(request.decodeTokensPerSecond),
            ]
            .map { CSVFieldEncoder.encode($0) }.joined(separator: ","))
    }
    try (csv.joined(separator: "\n") + "\n").write(
        to: output.appendingPathComponent("requests.csv"), atomically: true, encoding: .utf8)
    print(
        "Replayed \(decoded.envelopes.count) events; exported \(requests.count) completed requests")
    if decoded.drops.total > 0 || sampleDrops > 0 { exit(1) }
} catch {
    fail("Could not read or export bounded session files (\(type(of: error)))")
}
