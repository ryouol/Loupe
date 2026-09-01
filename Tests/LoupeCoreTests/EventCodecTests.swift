import XCTest

@testable import LoupeCore

final class EventCodecTests: XCTestCase {
    func testDropCounterRecordsReason() {
        var counter = EventDropCounter()
        counter.record(.malformedJSON)
        XCTAssertEqual(counter.total, 1)
        XCTAssertEqual(counter.byReason["malformed_json"], 1)
    }

    /// Tests run from anywhere, so locate the repo through this file's path.
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private func exampleLines(_ relativePath: String) throws -> [Data] {
        let url = Self.repoRoot.appendingPathComponent(relativePath)
        let blob = try Data(contentsOf: url)
        return blob.split(separator: UInt8(ascii: "\n")).map { Data($0) }
    }

    func testValidExamplesRoundTripLosslessly() throws {
        let decoder = EventLineDecoder()
        let encoder = EventLineEncoder()
        let lines = try exampleLines("protocol/examples/v3-events.ndjson")
        XCTAssertEqual(lines.count, 16, "example file changed without updating tests")

        for line in lines {
            switch decoder.decode(line: line) {
            case .success(let envelope):
                let reencoded = try encoder.encode(envelope)
                switch decoder.decode(line: reencoded) {
                case .success(let second):
                    XCTAssertEqual(envelope, second, "lossy round trip")
                case .failure(let reason):
                    XCTFail("re-decode dropped: \(reason)")
                }
            case .failure(let reason):
                XCTFail(
                    "valid example dropped as \(reason): \(String(decoding: line, as: UTF8.self))")
            }
        }
    }

    func testValidExamplesFormOneSemanticStream() throws {
        var validator = EventStreamValidator()
        let decoder = EventLineDecoder()
        for line in try exampleLines("protocol/examples/v3-events.ndjson") {
            let envelope = try decoder.decode(line: line).get()
            XCTAssertTrue(validator.accepts(envelope))
        }
        XCTAssertTrue(validator.hasTerminalSummary)
    }

    func testStreamValidatorRejectsReusedRequestIdentifier() {
        var validator = EventStreamValidator()
        let events = [
            EventEnvelope(
                ts: 1, runId: "r", requestId: nil,
                payload: .sessionStart(
                    .init(adapter: "a", adapterVersion: "1", runtime: "r", pid: 1))),
            EventEnvelope(
                ts: 2, runId: "r", requestId: "q",
                payload: .requestStart(.init(promptTokens: nil))),
            EventEnvelope(
                ts: 3, runId: "r", requestId: "q",
                payload: .requestEnd(.init(outputTokens: 0, finishReason: "error"))),
            EventEnvelope(
                ts: 4, runId: "r", requestId: "q",
                payload: .requestStart(.init(promptTokens: nil))),
        ]
        XCTAssertEqual(events.map { validator.accepts($0) }, [true, true, true, false])
    }

    func testStreamValidatorAcceptsMultipleClosedProducerWindows() {
        let payload = EventPayload.sessionStart(
            .init(adapter: "a", adapterVersion: "1", runtime: "r", pid: 1))
        let events = [
            EventEnvelope(
                version: EventProtocol.version, sequence: 1, ts: 1, runId: "r",
                requestId: nil,
                payload: payload),
            EventEnvelope(
                version: EventProtocol.version, sequence: 2, ts: 2, runId: "r",
                requestId: nil,
                payload: .transportSummary(
                    .init(attemptedEvents: 1, producerDroppedEvents: 0))),
            EventEnvelope(
                version: EventProtocol.version, sequence: 1, ts: 3, runId: "r",
                requestId: nil,
                payload: payload),
            EventEnvelope(
                version: EventProtocol.version, sequence: 2, ts: 4, runId: "r",
                requestId: nil,
                payload: .transportSummary(
                    .init(attemptedEvents: 1, producerDroppedEvents: 0))),
        ]
        var validator = EventStreamValidator()
        XCTAssertTrue(events.allSatisfy { validator.accepts($0) })
        XCTAssertTrue(validator.hasTerminalSummary)
    }

    func testStreamValidatorKeepsReplacementAfterInterruptedWindowReplayable() {
        let start = EventPayload.sessionStart(
            .init(adapter: "a", adapterVersion: "2", runtime: "r", pid: 1))
        let events = [
            EventEnvelope(
                version: EventProtocol.version, sequence: 1, ts: 1, runId: "r",
                requestId: nil, payload: start),
            EventEnvelope(
                version: EventProtocol.version, sequence: 2, ts: 2, runId: "r",
                requestId: "q-first", payload: .requestStart(.init(promptTokens: 1))),
            EventEnvelope(
                version: EventProtocol.version, sequence: 1, ts: 3, runId: "r",
                requestId: nil, payload: start),
            EventEnvelope(
                version: EventProtocol.version, sequence: 2, ts: 4, runId: "r",
                requestId: nil,
                payload: .transportSummary(
                    .init(attemptedEvents: 1, producerDroppedEvents: 0))),
        ]

        var validator = EventStreamValidator()
        XCTAssertTrue(events.allSatisfy { validator.accepts($0) })
        XCTAssertFalse(validator.hasOpenRequests)
        XCTAssertFalse(
            validator.hasTerminalSummary,
            "an interrupted earlier window prevents an all-windows-complete claim")
    }

    func testExamplesCoverEveryEventKind() throws {
        let decoder = EventLineDecoder()
        let lines = try exampleLines("protocol/examples/v3-events.ndjson")
        let kinds = lines.compactMap { try? decoder.decode(line: $0).get().kind }
        XCTAssertEqual(Set(kinds), Set(EventKind.allCases))
    }

    func testExtremeUnsignedValuesSurvive() throws {
        let decoder = EventLineDecoder()
        let lines = try exampleLines("protocol/examples/v3-events.ndjson")
        // One example carries UInt64.max / UInt32.max on purpose.
        guard
            let line = lines.first(where: {
                (try? decoder.decode(line: $0).get().kind) == .decodeTick
                    && String(decoding: $0, as: UTF8.self).contains("4294967295")
            }),
            case .success(let envelope) = decoder.decode(line: line),
            case .decodeTick(let tick) = envelope.payload
        else {
            XCTFail("expected trailing decode_tick example")
            return
        }
        XCTAssertEqual(envelope.ts, UInt64.max - 2)
        XCTAssertEqual(tick.outputTokens, UInt32.max)
        XCTAssertEqual(tick.kvCacheBytes, UInt64.max)
    }

    func testProtocolV2ReplayRetainsLegacyUnprovenancedKVField() throws {
        let lines = try exampleLines("protocol/examples/v2-events.ndjson")
        let decoded = try lines.map { try EventLineDecoder().decode(line: $0).get() }
        XCTAssertTrue(decoded.allSatisfy { $0.v == EventProtocol.sequencedVersion })
        guard case .decodeTick(let tick) = decoded.first(where: { $0.kind == .decodeTick })?.payload
        else { return XCTFail("missing v2 decode tick") }
        XCTAssertNotNil(tick.kvCacheBytes)
        XCTAssertNil(tick.memoryProvenance)
    }

    func testV3DecodeMemoryRequiresTruthfulExclusiveProvenance() {
        let payloads = [
            #"{"outputTokens":1,"kvCacheBytes":2,"activeMemoryBytes":3}"#,
            #"{"outputTokens":1,"kvCacheBytes":2,"allocatorMemoryGrowthBytes":2,"activeMemoryBytes":3,"memoryProvenance":"allocator_delta_proxy"}"#,
        ]
        for payload in payloads {
            let line = Data(
                (#"{"v":3,"seq":1,"ts":1,"runId":"r","requestId":"q","event":"decode_tick","payload":"#
                    + payload + "}").utf8)
            guard case .failure(let reason) = EventLineDecoder().decode(line: line) else {
                return XCTFail("invalid memory provenance decoded")
            }
            XCTAssertEqual(reason.label, "invalid_payload")
        }
    }

    func testLegacyV1ReplayRemainsCompatibleWithoutSequence() throws {
        let decoder = EventLineDecoder()
        let lines = try exampleLines("protocol/examples/v1-events.ndjson")
        XCTAssertEqual(lines.count, 14)
        for line in lines {
            let envelope = try decoder.decode(line: line).get()
            XCTAssertEqual(envelope.v, EventProtocol.legacyVersion)
            XCTAssertNil(envelope.sequence)
        }
    }

    func testMalformedLinesDropWithExpectedReasonsAndNeverCrash() throws {
        let decoder = EventLineDecoder()
        let lines = try exampleLines("protocol/examples/v1-malformed.ndjson")
        // Ordered to match the committed file; the Python suite asserts the
        // identical sequence so both decoders classify alike.
        let expected: [String] = [
            "malformed_json",
            "malformed_json",
            "unsupported_version",
            "unknown_event",
            "invalid_payload",
            "invalid_payload",
            "missing_request_id",
            "invalid_envelope",
            "invalid_envelope",
        ]
        XCTAssertEqual(lines.count, expected.count)

        var counter = EventDropCounter()
        for (index, line) in lines.enumerated() {
            switch decoder.decode(line: line) {
            case .success(let envelope):
                XCTFail("malformed line \(index + 1) decoded as \(envelope.kind)")
            case .failure(let reason):
                counter.record(reason)
                XCTAssertEqual(reason.label, expected[index], "line \(index + 1)")
            }
        }
        XCTAssertEqual(counter.total, expected.count)
        XCTAssertEqual(counter.byReason["malformed_json"], 2)
        XCTAssertEqual(counter.byReason["invalid_payload"], 2)
        XCTAssertEqual(counter.byReason["invalid_envelope"], 2)
    }

    func testLineCapMatchesSchemaLimit() throws {
        let schemaURL = Self.repoRoot.appendingPathComponent("protocol/events.schema.json")
        let schema =
            try JSONSerialization.jsonObject(with: Data(contentsOf: schemaURL)) as? [String: Any]
        let limits = schema?["x-limits"] as? [String: Any]
        XCTAssertEqual(limits?["maxLineBytes"] as? Int, EventLineDecoder.maxLineBytes)
    }

    func testOversizedLineIsRejectedBeforeParsing() {
        let decoder = EventLineDecoder()
        let oversized = Data(repeating: UInt8(ascii: "a"), count: EventLineDecoder.maxLineBytes + 1)
        var counter = EventDropCounter()
        switch decoder.decode(line: oversized) {
        case .success:
            XCTFail("oversized line must drop")
        case .failure(let reason):
            counter.record(reason)
            XCTAssertEqual(reason, .oversizedLine(bytes: oversized.count))
        }
        XCTAssertEqual(counter.total, 1)
    }

    func testEncoderOmitsNilRequestID() throws {
        let envelope = EventEnvelope(
            ts: 1,
            runId: "r-x",
            requestId: nil,
            payload: .error(ErrorPayload(code: "c", message: "m")))
        let data = try EventLineEncoder().encode(envelope)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("requestId"))
        XCTAssertFalse(text.contains("\\/"), "slashes must not be escaped in NDJSON output")
    }

    func testSchemaConstraintsAreEnforcedBeyondCodableShape() {
        let decoder = EventLineDecoder()
        let cases: [(String, String)] = [
            (
                #"{"v":1,"ts":1,"runId":"","event":"model_load_start","payload":{"modelId":"m"}}"#,
                "invalid_envelope"
            ),
            (
                #"{"v":1,"ts":1,"runId":"r","event":"session_start","payload":{"adapter":"a","adapterVersion":"1","runtime":"mlx","pid":0}}"#,
                "invalid_payload"
            ),
            (
                #"{"v":1,"ts":1,"runId":"r","event":"model_load_start","extra":true,"payload":{"modelId":"m"}}"#,
                "invalid_envelope"
            ),
            (
                #"{"v":1,"ts":1,"runId":"r","event":"model_load_start","payload":{"modelId":"m","extra":true}}"#,
                "invalid_payload"
            ),
            (
                #"{"v":1,"ts":1,"runId":"r","requestId":"","event":"request_start","payload":{}}"#,
                "invalid_envelope"
            ),
        ]

        for (line, reason) in cases {
            switch decoder.decode(line: Data(line.utf8)) {
            case .success:
                XCTFail("schema-invalid input was accepted: \(line)")
            case .failure(let failure):
                XCTAssertEqual(failure.label, reason, line)
            }
        }
    }
}
