import XCTest

@testable import LoupeCore

final class SessionCompletionTests: XCTestCase {
    func testCancelledAndFailedRequestsDoNotBecomeSuccessfulPerformanceEvidence() {
        for reason in ["stop", "length", "eos", "cancelled", "error", "other"] {
            let events = [
                EventEnvelope(
                    ts: 100, runId: "r", requestId: "q", payload: .requestStart(.init())),
                EventEnvelope(
                    ts: 200, runId: "r", requestId: "q",
                    payload: .prefillEnd(.init(promptTokens: 10))),
                EventEnvelope(
                    ts: 250, runId: "r", requestId: "q",
                    payload: .decodeTick(.init(outputTokens: 1, activeMemoryBytes: 100))),
                EventEnvelope(
                    ts: 400, runId: "r", requestId: "q",
                    payload: .requestEnd(
                        .init(outputTokens: 2, finishReason: reason, decodeDurationNs: 200))),
            ]
            XCTAssertEqual(
                SessionMetrics.perRequest(events: events).count,
                ["stop", "length", "eos"].contains(reason) ? 1 : 0, reason)
            XCTAssertTrue(SessionMetrics.perRequest(events: Array(events.dropLast())).isEmpty)
        }
    }
}
