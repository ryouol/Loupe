import Darwin
import Foundation
import LoupeCore
import LoupeLlamaCpp

// Drives llama-server completions and streams current-protocol events to the
// Loupe app. The server is observed from outside: per-request truth from
// /completion timings, gauges from /metrics at 10 Hz, PID resolved from the
// listening socket so the app can attach per-process telemetry.

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

func log(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

var serverURL = URL(string: "http://127.0.0.1:8080")
var socketPath =
    ProcessInfo.processInfo.environment[LoupeEnvironment.adapterSocketVariable]
    ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("Loupe")
    .appendingPathComponent(LoupeUserRuntime.directoryName)
    .appendingPathComponent(LoupeUserRuntime.adapterSocketName).path
var prompt = "Explain the difference between prefill and decode in one sentence."
var promptFromStdin = false
var maxTokens = 64
var kvLayers: Int?
var kvHeadDimension: Int?
var kvHeads: Int?
var kvBytesPerElement: Int?

do {
    try PromptInput.validateCommandLine(Array(CommandLine.arguments.dropFirst()))
} catch {
    fail("inline --prompt text is unsupported; pipe bounded UTF-8 to --prompt-stdin")
}
var arguments = CommandLine.arguments.dropFirst().makeIterator()
while let argument = arguments.next() {
    switch argument {
    case "--server":
        guard let value = arguments.next(), let parsed = URL(string: value) else {
            fail("--server requires a valid URL")
        }
        serverURL = parsed
    case "--socket":
        guard let value = arguments.next() else { fail("--socket requires a path") }
        socketPath = value
    case "--prompt-stdin":
        guard !promptFromStdin else { fail("--prompt-stdin may be supplied once") }
        promptFromStdin = true
    case "--max-tokens":
        guard let value = arguments.next().flatMap(Int.init) else {
            fail("--max-tokens requires an integer")
        }
        maxTokens = value
    case "--kv-layers":
        guard let value = arguments.next().flatMap(Int.init) else {
            fail("--kv-layers requires an integer")
        }
        kvLayers = value
    case "--kv-head-dim":
        guard let value = arguments.next().flatMap(Int.init) else {
            fail("--kv-head-dim requires an integer")
        }
        kvHeadDimension = value
    case "--kv-heads":
        guard let value = arguments.next().flatMap(Int.init) else {
            fail("--kv-heads requires an integer")
        }
        kvHeads = value
    case "--kv-bytes-per-element":
        guard let value = arguments.next().flatMap(Int.init) else {
            fail("--kv-bytes-per-element requires an integer")
        }
        kvBytesPerElement = value
    default:
        fail(
            "usage: loupe-llamacpp [--server url] [--socket path] [--prompt-stdin] "
                + "[--max-tokens n] --kv-layers n --kv-head-dim n --kv-heads n "
                + "--kv-bytes-per-element n")
    }
}
guard let serverURL else { fail("invalid --server URL") }
if promptFromStdin {
    do {
        prompt = try PromptInput.read()
    } catch {
        fail("--prompt-stdin requires 1 to 65536 bytes of valid UTF-8")
    }
}
guard let scheme = serverURL.scheme?.lowercased(), ["http", "https"].contains(scheme),
    serverURL.user == nil, serverURL.password == nil,
    let host = serverURL.host?.lowercased(),
    ["127.0.0.1", "::1"].contains(host)
else {
    fail(
        "--server must use the numeric loopback address 127.0.0.1 or ::1 without credentials"
    )
}
guard let kvLayers, let kvHeadDimension, let kvHeads, let kvBytesPerElement else {
    fail(
        "--kv-layers, --kv-head-dim, --kv-heads, and --kv-bytes-per-element "
            + "are required model geometry")
}
guard (1...4_096).contains(maxTokens), prompt.utf8.count <= PromptInput.maxBytes,
    (1...512).contains(kvLayers), (1...1_024).contains(kvHeadDimension),
    (1...256).contains(kvHeads), (1...16).contains(kvBytesPerElement)
else { fail("token, prompt, or KV dimensions exceed safe adapter limits") }
guard !socketPath.isEmpty,
    socketPath.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path)
else { fail("adapter socket path is empty or too long") }

let kvModel = KVCacheModel(
    layers: kvLayers, headDimension: kvHeadDimension, kvHeads: kvHeads,
    bytesPerElement: kvBytesPerElement)
let runId =
    ProcessInfo.processInfo.environment[LoupeEnvironment.runIDVariable]
    ?? "r-\(UUID().uuidString.prefix(8).lowercased())"
guard !runId.isEmpty, runId.count <= 128 else {
    fail("LOUPE_RUN_ID must contain 1 to 128 characters")
}
let timebase = Timebase.live()
let writer = UnixSocketLineWriter(socketPath: socketPath)
let encoder = EventLineEncoder()
let httpSession = AdapterHTTP.session()
var sequence: UInt64 = 0

@MainActor
func emit(_ envelope: EventEnvelope) {
    sequence += 1
    let sequenced = EventEnvelope(
        version: EventProtocol.version, sequence: sequence, ts: envelope.ts,
        runId: envelope.runId, requestId: envelope.requestId, payload: envelope.payload)
    if let line = try? encoder.encode(sequenced) {
        writer.send(line)
    }
}

@MainActor
func finishWriter() {
    let attempted = sequence
    emit(
        EventEnvelope(
            ts: timebase.nowNanoseconds(), runId: runId, requestId: nil,
            payload: .transportSummary(
                TransportSummaryPayload(
                    attemptedEvents: attempted,
                    producerDroppedEvents: UInt64(max(0, writer.dropped))))))
    writer.close()
}

do {
    let defaultPort = scheme == "https" ? 443 : 80
    guard let port = UInt16(exactly: serverURL.port ?? defaultPort), port > 0 else {
        throw AdapterFailure.invalidServerPort
    }
    guard let serverPID = ListeningPortResolver.pid(listeningAt: host, port: port) else {
        throw AdapterFailure.serverProcessNotFound(port)
    }

    let props: LlamaServerProps = try await fetchJSON(
        serverURL.appendingPathComponent("props"), session: httpSession)
    log("llama-server: n_ctx \(props.defaultGenerationSettings.nCtx), pid \(serverPID)")

    emit(
        EventEnvelope(
            ts: timebase.nowNanoseconds(), runId: runId, requestId: nil,
            payload: .sessionStart(
                SessionStartPayload(
                    adapter: "loupe-llamacpp", adapterVersion: Loupe.version,
                    runtime: "llama.cpp", pid: serverPID))))
    let now = timebase.nowNanoseconds()
    emit(
        EventEnvelope(
            ts: now, runId: runId, requestId: nil,
            payload: .clockSync(ClockSyncPayload(t0: now, t1: now, t2: now, t3: now))))

    let poller = MetricsPoller(
        url: serverURL.appendingPathComponent("metrics"), session: httpSession)
    await poller.start()

    let startNs = timebase.nowNanoseconds()
    // The same logical run may relaunch this adapter; a nonce prevents its
    // one-request counter from colliding with evidence already persisted.
    let requestID =
        "q-\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"
    // Persist the attempt before network I/O so cancellation remains visible.
    emit(
        EventEnvelope(
            ts: startNs, runId: runId, requestId: requestID,
            payload: .requestStart(RequestStartPayload(promptTokens: nil))))
    let (chunks, arrivals) = try await streamCompletion(
        server: serverURL, prompt: prompt, maxTokens: maxTokens,
        timebase: timebase, session: httpSession)
    for envelope in LlamaRequestTrace.events(
        runId: runId, requestId: requestID, requestStartNs: startNs,
        chunkArrivalsNs: arrivals, chunks: chunks, kv: kvModel
    ).dropFirst() {
        emit(envelope)
    }

    await poller.stop()
    if let kvUsage = await poller.maxima["llamacpp:kv_cache_usage_ratio"] {
        log("kv cache usage peaked at \(String(format: "%.1f", kvUsage * 100))%")
    }
    log("dropped socket lines: \(writer.dropped)")
    finishWriter()
} catch {
    emit(
        EventEnvelope(
            ts: timebase.nowNanoseconds(), runId: runId, requestId: nil,
            payload: .error(
                ErrorPayload(code: "adapter_failed", message: evidenceErrorMessage(error)))))
    finishWriter()
    fail("loupe-llamacpp failed: \(error)")
}

enum AdapterFailure: Error {
    case invalidServerPort
    case serverProcessNotFound(UInt16)
    case invalidHTTPResponse
    case responseTooLarge
    case streamLineTooLarge
    case tooManyChunks
}

/// Persisted evidence is intentionally less detailed than local stderr:
/// networking and decoding errors can embed URLs, response snippets, or
/// other user data. The evidence stream keeps only a bounded error category.
func evidenceErrorMessage(_ error: Error) -> String {
    if let failure = error as? AdapterFailure {
        switch failure {
        case .invalidServerPort: return "The local server port was invalid."
        case .serverProcessNotFound: return "No same-user local server process was found."
        case .invalidHTTPResponse: return "The local server returned an invalid response."
        case .responseTooLarge: return "The local server response exceeded the safety limit."
        case .streamLineTooLarge: return "A local server stream line exceeded the safety limit."
        case .tooManyChunks: return "The local server returned too many stream chunks."
        }
    }
    return "The local llama.cpp request failed (\(String(describing: type(of: error))))."
}

func fetchJSON<T: Decodable>(_ url: URL, session: URLSession) async throws -> T {
    let (data, response) = try await AdapterHTTP.boundedData(
        from: url, session: session, maximumBytes: AdapterHTTP.maxMetadataBytes)
    guard AdapterHTTP.isSuccessful(response) else { throw AdapterFailure.invalidHTTPResponse }
    return try JSONDecoder().decode(T.self, from: data)
}

/// Streams /completion, timestamping every SSE chunk on arrival.
func streamCompletion(
    server: URL, prompt: String, maxTokens: Int, timebase: Timebase,
    session: URLSession
) async throws -> ([LlamaCompletionChunk], [UInt64]) {
    var request = URLRequest(url: server.appendingPathComponent("completion"))
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: [
        "prompt": prompt,
        "n_predict": maxTokens,
        "stream": true,
        "timings_per_token": false,
        "temperature": 0,
        "seed": 42,
        "cache_prompt": false,
    ])

    request.timeoutInterval = 300
    var chunks: [LlamaCompletionChunk] = []
    var arrivals: [UInt64] = []
    let decoder = JSONDecoder()
    let (bytes, response) = try await session.bytes(for: request)
    guard AdapterHTTP.isSuccessful(response) else { throw AdapterFailure.invalidHTTPResponse }
    var line = Data()
    var receivedBytes = 0
    stream: for try await byte in bytes {
        receivedBytes += 1
        guard receivedBytes <= AdapterHTTP.maxStreamBytes else {
            throw AdapterFailure.responseTooLarge
        }
        if byte == UInt8(ascii: "\n") {
            let text = String(decoding: line, as: UTF8.self)
            line.removeAll(keepingCapacity: true)
            guard let payload = SSEParser.dataPayloads(text + "\n").first else { continue }
            let chunk = try decoder.decode(LlamaCompletionChunk.self, from: payload)
            guard chunks.count < maxTokens + 8 else { throw AdapterFailure.tooManyChunks }
            chunks.append(chunk)
            arrivals.append(timebase.nowNanoseconds())
            if chunk.stop { break stream }
        } else {
            guard line.count < AdapterHTTP.maxLineBytes else {
                throw AdapterFailure.streamLineTooLarge
            }
            line.append(byte)
        }
    }
    return (chunks, arrivals)
}
