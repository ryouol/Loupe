import Darwin
import Foundation
import XCTest

@testable import LoupeCore
@testable import LoupeLlamaCpp

/// Everything here runs from the recorded fixtures under fixtures/llamacpp/
/// — no live server needed, per the acceptance.
final class LoupeLlamaCppTests: XCTestCase {
    private static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("fixtures/llamacpp")

    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: Self.fixtures.appendingPathComponent(name))
    }

    // MARK: /props

    func testPropsParseFromRecordedResponse() throws {
        let props = try JSONDecoder().decode(LlamaServerProps.self, from: fixture("props.json"))
        XCTAssertEqual(props.defaultGenerationSettings.nCtx, 32_768)
        XCTAssertEqual(props.totalSlots, 4)
        XCTAssertTrue(props.modelPath?.hasSuffix(".gguf") ?? false)
    }

    // MARK: /metrics

    func testMetricsParseFromRecordedResponses() throws {
        let idle = PrometheusParser.parse(
            String(decoding: try fixture("metrics-idle.txt"), as: UTF8.self))
        let after = PrometheusParser.parse(
            String(decoding: try fixture("metrics-after.txt"), as: UTF8.self))

        XCTAssertEqual(idle["llamacpp:prompt_tokens_total"], 0)
        XCTAssertEqual(after["llamacpp:prompt_tokens_total"], 13)
        XCTAssertEqual(after["llamacpp:tokens_predicted_total"], 25)
        XCTAssertEqual(after["llamacpp:requests_processing"], 0)
        // Comment lines must not become series.
        XCTAssertNil(after["#"])
    }

    func testPrometheusParserToleratesLabelsAndJunk() {
        let parsed = PrometheusParser.parse(
            """
            # HELP something
            metric_with_labels{slot="0",state="idle"} 42
            broken line without value
            plain_metric 7.5
            """)
        XCTAssertEqual(parsed["metric_with_labels"], 42)
        XCTAssertEqual(parsed["plain_metric"], 7.5)
        XCTAssertEqual(parsed.count, 2)
    }

    func testPrometheusParserRejectsNonFiniteValues() {
        let parsed = PrometheusParser.parse(
            """
            finite 12.5
            nan NaN
            positive_inf +Inf
            negative_inf -Inf
            """)
        XCTAssertEqual(parsed, ["finite": 12.5])
    }

    func testHTTPClientUsesNoRedirectDelegateOrProxy() {
        let session = AdapterHTTP.session()
        XCTAssertTrue(session.delegate is LocalOnlySessionDelegate)
        XCTAssertEqual(session.configuration.connectionProxyDictionary?.count, 0)
        session.invalidateAndCancel()
    }

    // MARK: /completion stream

    func testCompletionStreamParsesChunksAndTimings() throws {
        let body = String(decoding: try fixture("completion-stream.txt"), as: UTF8.self)
        let chunks = SSEParser.chunks(body)

        XCTAssertEqual(chunks.count, 26)
        // 24 content-bearing chunks: the 25th predicted token is the EOS,
        // which arrives inside the terminal stop chunk with empty content.
        XCTAssertEqual(chunks.filter { !$0.content.isEmpty }.count, 24)
        XCTAssertTrue(chunks.last?.stop ?? false)
        XCTAssertEqual(
            chunks.last?.timings?.predictedN,
            chunks.filter { !$0.content.isEmpty }.count + 1,
            "predicted_n counts the invisible stop token")

        let timings = try XCTUnwrap(chunks.last?.timings)
        XCTAssertEqual(timings.promptN, 13)
        XCTAssertEqual(timings.promptMs, 148.117, accuracy: 0.001)
        XCTAssertEqual(timings.predictedN, 25)
        XCTAssertEqual(timings.predictedPerSecond, 220.32, accuracy: 0.01)
    }

    // MARK: KV model

    func testKVCacheBytesFromArchitectureParams() {
        // Qwen2.5-0.5B: 24 layers, GQA with 2 KV heads of dim 64, f16 cache.
        let kv = KVCacheModel(layers: 24, headDimension: 64, kvHeads: 2)
        // K + V = 2 × 24 × 2 × 64 × 2 bytes = 12,288 bytes per token.
        XCTAssertEqual(kv.bytesPerToken, 12_288)
        XCTAssertEqual(kv.bytes(forTokens: 38), 466_944)
        XCTAssertEqual(kv.bytes(forTokens: 0), 0)
        XCTAssertEqual(kv.bytes(forTokens: -5), 0)
    }

    func testKVCacheArithmeticSaturatesHostileDimensions() {
        let kv = KVCacheModel(
            layers: Int.max, headDimension: Int.max, kvHeads: Int.max,
            bytesPerElement: Int.max)
        XCTAssertEqual(kv.bytesPerToken, Int.max)
        XCTAssertEqual(kv.bytes(forTokens: Int.max), UInt64.max)
    }

    // MARK: Event mapping

    func testRecordedExchangeMapsToProtocolEvents() throws {
        let body = String(decoding: try fixture("completion-stream.txt"), as: UTF8.self)
        let chunks = SSEParser.chunks(body)
        let start: UInt64 = 1_000_000_000
        // Synthetic arrivals 5ms apart — the recorded body carries no wire
        // timestamps; arrival timing is the adapter's own clock in live use.
        let arrivals = (0..<chunks.count).map { start + 200_000_000 + UInt64($0) * 5_000_000 }
        let kv = KVCacheModel(layers: 24, headDimension: 64, kvHeads: 2)

        let events = LlamaRequestTrace.events(
            runId: "r-fixture", requestId: "q-1", requestStartNs: start,
            chunkArrivalsNs: arrivals, chunks: chunks, kv: kv)

        XCTAssertEqual(events.first?.kind, .requestStart)
        XCTAssertEqual(events[1].kind, .prefillEnd)
        XCTAssertEqual(events.last?.kind, .requestEnd)
        // Ticks are observable emissions (24); request_end reports the
        // server-true 25 including the stop token.
        XCTAssertEqual(events.filter { $0.kind == .decodeTick }.count, 24)

        // prefill_end comes from the server's own prompt_ms, not arrival time.
        XCTAssertEqual(events[1].ts, start + UInt64(148.117 * 1_000_000))
        guard case .prefillEnd(let prefill) = events[1].payload else {
            return XCTFail("expected prefill payload")
        }
        XCTAssertEqual(prefill.promptTokens, 13)

        // KV grows by the computed per-token size from the prompt baseline.
        let ticks = events.compactMap { envelope -> DecodeTickPayload? in
            guard case .decodeTick(let tick) = envelope.payload else { return nil }
            return tick
        }
        XCTAssertEqual(ticks.first?.kvCacheBytes, UInt64((13 + 1) * 12_288))
        XCTAssertEqual(ticks.last?.kvCacheBytes, UInt64((13 + 24) * 12_288))

        guard case .requestEnd(let end) = events.last?.payload else {
            return XCTFail("expected requestEnd payload")
        }
        XCTAssertEqual(end.outputTokens, 25)
        XCTAssertEqual(end.finishReason, "stop")
        XCTAssertNotNil(end.decodeDurationNs)
        XCTAssertEqual(
            SessionMetrics.perRequest(events: events).first?.decodeTokensPerSecond ?? -1,
            220.32, accuracy: 0.01)

        // The whole trace validates against the wire contract.
        let encoder = EventLineEncoder()
        let decoder = EventLineDecoder()
        for envelope in events {
            let line = try encoder.encode(envelope)
            if case .failure(let reason) = decoder.decode(line: line) {
                XCTFail("mapped event failed protocol validation: \(reason)")
            }
        }
        let timestamps = events.map(\.ts)
        XCTAssertEqual(timestamps, timestamps.sorted(), "trace must be time-ordered")
    }

    func testStreamWithoutTimingsProducesErrorTrace() {
        let chunks = [LlamaCompletionChunk(content: "hi", stop: false, timings: nil)]
        let events = LlamaRequestTrace.events(
            runId: "r", requestId: "q-1", requestStartNs: 10,
            chunkArrivalsNs: [20], chunks: chunks,
            kv: KVCacheModel(layers: 1, headDimension: 1, kvHeads: 1))
        XCTAssertEqual(events.map(\.kind), [.requestStart, .error, .requestEnd])
    }

    func testExtremeFiniteTimingsSaturateWithoutTrapping() {
        let timings = LlamaTimings(
            promptN: Int.max, promptMs: .greatestFiniteMagnitude,
            predictedN: Int.max, predictedMs: .greatestFiniteMagnitude,
            predictedPerSecond: 1)
        let chunks = [
            LlamaCompletionChunk(content: "x", stop: true, timings: timings)
        ]
        let events = LlamaRequestTrace.events(
            runId: "r", requestId: "q-1", requestStartNs: UInt64.max - 5,
            chunkArrivalsNs: [UInt64.max - 1], chunks: chunks,
            kv: KVCacheModel(layers: 1, headDimension: 1, kvHeads: 1))

        XCTAssertEqual(events.map(\.ts), events.map(\.ts).sorted())
        XCTAssertEqual(events.last?.ts, UInt64.max)
    }

    func testOneTokenEarlyStopPreservesRuntimeReportedRate() {
        let timings = LlamaTimings(
            promptN: 8, promptMs: 100, predictedN: 1, predictedMs: 50,
            predictedPerSecond: 20)
        let chunks = [
            LlamaCompletionChunk(content: "x", stop: true, timings: timings)
        ]
        let events = LlamaRequestTrace.events(
            runId: "r", requestId: "q", requestStartNs: 1_000,
            chunkArrivalsNs: [1_001], chunks: chunks,
            kv: KVCacheModel(layers: 1, headDimension: 1, kvHeads: 1))

        let metric = SessionMetrics.perRequest(events: events).first
        XCTAssertEqual(metric?.outputTokens, 1)
        XCTAssertEqual(metric?.decodeDurationNs, 50_000_000)
        XCTAssertEqual(metric?.decodeTokensPerSecond ?? -1, 20, accuracy: 0.001)
    }

    func testMissingRuntimeMillisecondsFallsBackToReportedRate() {
        let timings = LlamaTimings(
            promptN: 8, promptMs: 100, predictedN: 1, predictedMs: 0,
            predictedPerSecond: 25)
        let events = LlamaRequestTrace.events(
            runId: "r", requestId: "q", requestStartNs: 1_000,
            chunkArrivalsNs: [1_001],
            chunks: [LlamaCompletionChunk(content: "x", stop: true, timings: timings)],
            kv: KVCacheModel(layers: 1, headDimension: 1, kvHeads: 1))

        let metric = SessionMetrics.perRequest(events: events).first
        XCTAssertEqual(metric?.decodeDurationNs, 40_000_000)
        XCTAssertEqual(metric?.decodeTokensPerSecond ?? -1, 25, accuracy: 0.001)
    }

    func testRuntimeRateFallbackSaturatesWithoutConversionTrap() {
        let timings = LlamaTimings(
            promptN: 1, promptMs: 1, predictedN: 1, predictedMs: 0,
            predictedPerSecond: .leastNonzeroMagnitude)
        let events = LlamaRequestTrace.events(
            runId: "r", requestId: "q", requestStartNs: 1,
            chunkArrivalsNs: [2],
            chunks: [LlamaCompletionChunk(content: "x", stop: true, timings: timings)],
            kv: KVCacheModel(layers: 1, headDimension: 1, kvHeads: 1))

        XCTAssertEqual(
            SessionMetrics.perRequest(events: events).first?.decodeDurationNs, UInt64.max)
    }

    // MARK: PID resolution

    func testResolvesOwnListeningSocket() throws {
        // Bind a listener ourselves: the resolver must attribute the port to
        // this very process, root-free.
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(bound, 0)
        XCTAssertEqual(listen(fd, 1), 0)

        var assigned = sockaddr_in()
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &assigned) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &size)
            }
        }
        let port = UInt16(bigEndian: assigned.sin_port)
        XCTAssertGreaterThan(port, 0)

        XCTAssertEqual(
            ListeningPortResolver.pid(listeningOn: port),
            ProcessInfo.processInfo.processIdentifier)
        XCTAssertNil(
            ListeningPortResolver.pid(listeningOn: 1),
            "nothing listens on port 1 without root")
    }

    func testSocketWriterReconnectsWhenListenerAppears() throws {
        let directory = URL(fileURLWithPath: "/tmp/loupe-llama-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let socketPath = directory.appendingPathComponent("adapter.sock").path
        let writer = UnixSocketLineWriter(socketPath: socketPath)

        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(listener, 0)
        defer { close(listener) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: Array(socketPath.utf8))
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(bound, 0)
        XCTAssertEqual(listen(listener, 1), 0)

        writer.send(Data("hello".utf8))
        let client = accept(listener, nil, nil)
        XCTAssertGreaterThanOrEqual(client, 0)
        defer { close(client) }
        var bytes = [UInt8](repeating: 0, count: 16)
        let count = read(client, &bytes, bytes.count)
        XCTAssertEqual(String(decoding: bytes.prefix(max(0, count)), as: UTF8.self), "hello\n")
        XCTAssertEqual(writer.dropped, 0)
        writer.close()
    }

    func testSocketWriterMissingListenerHasBoundedRetryCost() {
        let writer = UnixSocketLineWriter(
            socketPath: "/tmp/loupe-llama-missing-\(UUID().uuidString.prefix(8)).sock")
        let clock = ContinuousClock()
        let start = clock.now
        for _ in 0..<10_000 { writer.send(Data("line".utf8)) }
        let elapsed = clock.now - start

        XCTAssertEqual(writer.dropped, 10_000)
        XCTAssertLessThan(elapsed, .seconds(1))
        writer.close()
    }
}
