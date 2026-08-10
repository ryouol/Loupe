import Darwin
import Foundation
import LoupeCore
import LoupeLlamaCpp

// Drives llama-server completions and streams protocol-v1 events to the
// Loupe daemon. The server is observed from outside: per-request truth from
// /completion timings, gauges from /metrics at 10 Hz, PID resolved from the
// listening socket so the daemon can attach per-process telemetry.

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

func log(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

var serverURL = URL(string: "http://127.0.0.1:8080")
var socketPath = LoupeDaemon.adapterSocketPath
var prompt = "Explain the difference between prefill and decode in one sentence."
var maxTokens = 64
var kvLayers = 24
var kvHeadDimension = 64
var kvHeads = 2

var arguments = CommandLine.arguments.dropFirst().makeIterator()
while let argument = arguments.next() {
    switch argument {
    case "--server": serverURL = arguments.next().flatMap(URL.init(string:)) ?? serverURL
    case "--socket": socketPath = arguments.next() ?? socketPath
    case "--prompt": prompt = arguments.next() ?? prompt
    case "--max-tokens": maxTokens = arguments.next().flatMap(Int.init) ?? maxTokens
    case "--kv-layers": kvLayers = arguments.next().flatMap(Int.init) ?? kvLayers
    case "--kv-head-dim": kvHeadDimension = arguments.next().flatMap(Int.init) ?? kvHeadDimension
    case "--kv-heads": kvHeads = arguments.next().flatMap(Int.init) ?? kvHeads
    default:
        fail(
            "usage: loupe-llamacpp [--server url] [--socket path] [--prompt text] "
                + "[--max-tokens n] [--kv-layers n] [--kv-head-dim n] [--kv-heads n]")
    }
}
guard let serverURL else { fail("invalid --server URL") }

let kvModel = KVCacheModel(layers: kvLayers, headDimension: kvHeadDimension, kvHeads: kvHeads)
let runId = "r-\(UUID().uuidString.prefix(8).lowercased())"
let timebase = Timebase.live()
let writer = UnixSocketLineWriter(socketPath: socketPath)
let encoder = EventLineEncoder()

func emit(_ envelope: EventEnvelope) {
    if let line = try? encoder.encode(envelope) {
        writer.send(line)
    }
}

do {
    let port = UInt16(serverURL.port ?? 8080)
    let serverPID = ListeningPortResolver.pid(listeningOn: port)
    if serverPID == nil {
        log("warning: no local process listening on \(port); is llama-server up?")
    }

    let props: LlamaServerProps = try await fetchJSON(serverURL.appendingPathComponent("props"))
    log("llama-server: n_ctx \(props.defaultGenerationSettings.nCtx), pid \(serverPID ?? -1)")

    emit(
        EventEnvelope(
            ts: timebase.nowNanoseconds(), runId: runId, requestId: nil,
            payload: .sessionStart(
                SessionStartPayload(
                    adapter: "loupe-llamacpp", adapterVersion: Loupe.version,
                    runtime: "llama.cpp", pid: serverPID ?? 0))))
    let now = timebase.nowNanoseconds()
    emit(
        EventEnvelope(
            ts: now, runId: runId, requestId: nil,
            payload: .clockSync(ClockSyncPayload(t0: now, t1: now, t2: now, t3: now))))

    let poller = MetricsPoller(url: serverURL.appendingPathComponent("metrics"))
    await poller.start()

    let startNs = timebase.nowNanoseconds()
    let (chunks, arrivals) = try await streamCompletion(
        server: serverURL, prompt: prompt, maxTokens: maxTokens, timebase: timebase)
    for envelope in LlamaRequestTrace.events(
        runId: runId, requestId: "q-1", requestStartNs: startNs,
        chunkArrivalsNs: arrivals, chunks: chunks, kv: kvModel)
    {
        emit(envelope)
    }

    await poller.stop()
    if let kvUsage = await poller.maxima["llamacpp:kv_cache_usage_ratio"] {
        log("kv cache usage peaked at \(String(format: "%.1f", kvUsage * 100))%")
    }
    log("dropped socket lines: \(writer.dropped)")
    writer.close()
} catch {
    emit(
        EventEnvelope(
            ts: timebase.nowNanoseconds(), runId: runId, requestId: nil,
            payload: .error(
                ErrorPayload(code: "adapter_failed", message: "\(error)"))))
    writer.close()
    fail("loupe-llamacpp failed: \(error)")
}

func fetchJSON<T: Decodable>(_ url: URL) async throws -> T {
    let (data, _) = try await URLSession.shared.data(from: url)
    return try JSONDecoder().decode(T.self, from: data)
}

/// Streams /completion, timestamping every SSE chunk on arrival.
func streamCompletion(
    server: URL, prompt: String, maxTokens: Int, timebase: Timebase
) async throws -> ([LlamaCompletionChunk], [UInt64]) {
    var request = URLRequest(url: server.appendingPathComponent("completion"))
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: [
        "prompt": prompt,
        "n_predict": maxTokens,
        "stream": true,
        "timings_per_token": false,
    ])

    var chunks: [LlamaCompletionChunk] = []
    var arrivals: [UInt64] = []
    let decoder = JSONDecoder()
    let (bytes, _) = try await URLSession.shared.bytes(for: request)
    for try await line in bytes.lines {
        guard let payload = SSEParser.dataPayloads(line + "\n").first,
            let chunk = try? decoder.decode(LlamaCompletionChunk.self, from: payload)
        else { continue }
        chunks.append(chunk)
        arrivals.append(timebase.nowNanoseconds())
        if chunk.stop { break }
    }
    return (chunks, arrivals)
}
