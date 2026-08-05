import XCTest

@testable import LoupeCore

final class EventCodecTests: XCTestCase {
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
        let lines = try exampleLines("protocol/examples/v1-events.ndjson")
        XCTAssertEqual(lines.count, 14, "example file changed without updating tests")

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

    func testExamplesCoverEveryEventKind() throws {
        let decoder = EventLineDecoder()
        let lines = try exampleLines("protocol/examples/v1-events.ndjson")
        let kinds = lines.compactMap { try? decoder.decode(line: $0).get().kind }
        XCTAssertEqual(Set(kinds), Set(EventKind.allCases))
    }

    func testExtremeUnsignedValuesSurvive() throws {
        let decoder = EventLineDecoder()
        let lines = try exampleLines("protocol/examples/v1-events.ndjson")
        // The last example line carries UInt64.max / UInt32.max on purpose.
        guard let last = lines.last,
            case .success(let envelope) = decoder.decode(line: last),
            case .decodeTick(let tick) = envelope.payload
        else {
            XCTFail("expected trailing decode_tick example")
            return
        }
        XCTAssertEqual(envelope.ts, UInt64.max)
        XCTAssertEqual(tick.outputTokens, UInt32.max)
        XCTAssertEqual(tick.kvCacheBytes, UInt64.max)
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
}
