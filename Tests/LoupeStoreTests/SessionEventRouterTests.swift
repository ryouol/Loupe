import Foundation
import XCTest

@testable import LoupeCore
@testable import LoupeStore

final class SessionEventRouterTests: XCTestCase {
    private var directory: URL = FileManager.default.temporaryDirectory

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("loupe-router-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func envelope(
        runId: String, ts: UInt64, payload: EventPayload, requestId: String? = nil
    ) -> EventEnvelope {
        EventEnvelope(ts: ts, runId: runId, requestId: requestId, payload: payload)
    }

    func testRequestEndFlushesEagerly() async throws {
        let router = SessionEventRouter(directory: directory, host: .stub, flushThreshold: 1_000)
        try await router.route(
            envelope(
                runId: "r-1", ts: 1,
                payload: .sessionStart(
                    SessionStartPayload(
                        adapter: "a", adapterVersion: "1", runtime: "mlx", pid: 1))))
        try await router.route(
            envelope(
                runId: "r-1", ts: 2,
                payload: .requestStart(RequestStartPayload(promptTokens: 4)),
                requestId: "q-1"))
        try await router.route(
            envelope(
                runId: "r-1", ts: 3,
                payload: .requestEnd(RequestEndPayload(outputTokens: 9, finishReason: "stop")),
                requestId: "q-1"))

        let store = await router.persistedStore(runId: "r-1")
        let persisted = try await store?.events() ?? []
        XCTAssertEqual(
            persisted.map(\.kind), [.sessionStart, .requestStart, .requestEnd],
            "request_end must flush the whole pending batch")
    }

    func testBatchingHoldsUntilThresholdThenFlushes() async throws {
        let router = SessionEventRouter(directory: directory, host: .stub, flushThreshold: 5)
        for tick in 1...4 {
            try await router.route(
                envelope(
                    runId: "r-2", ts: UInt64(tick),
                    payload: .decodeTick(
                        DecodeTickPayload(
                            outputTokens: UInt32(tick), kvCacheBytes: 1, activeMemoryBytes: 1)),
                    requestId: "q-1"))
        }
        let maybeStore = await router.persistedStore(runId: "r-2")
        let store = try XCTUnwrap(maybeStore)
        let beforeThreshold = try await store.events()
        XCTAssertTrue(beforeThreshold.isEmpty, "below threshold nothing is persisted yet")

        try await router.route(
            envelope(
                runId: "r-2", ts: 5,
                payload: .decodeTick(
                    DecodeTickPayload(outputTokens: 5, kvCacheBytes: 1, activeMemoryBytes: 1)),
                requestId: "q-1"))
        let afterThreshold = try await store.events()
        XCTAssertEqual(afterThreshold.count, 5)
    }

    func testRunsRouteToSeparateStoresAndFlushAllDrains() async throws {
        let router = SessionEventRouter(directory: directory, host: .stub, flushThreshold: 100)
        try await router.route(
            envelope(runId: "r-a", ts: 1, payload: .modelLoadStart(.init(modelId: "m"))))
        try await router.route(
            envelope(runId: "r-b", ts: 2, payload: .modelLoadStart(.init(modelId: "m"))))
        try await router.flushAll()

        let maybeA = await router.persistedStore(runId: "r-a")
        let maybeB = await router.persistedStore(runId: "r-b")
        let storeA = try XCTUnwrap(maybeA)
        let storeB = try XCTUnwrap(maybeB)
        let eventsA = try await storeA.events()
        let eventsB = try await storeB.events()
        XCTAssertEqual(eventsA.count, 1)
        XCTAssertEqual(eventsB.count, 1)
        XCTAssertNotEqual(storeA.databaseURL, storeB.databaseURL)
    }

    func testExpectedRunAndSessionCountAreBounded() async throws {
        let pinned = SessionEventRouter(
            directory: directory, host: .stub, acceptedRunID: "expected")
        do {
            try await pinned.route(
                envelope(runId: "surprise", ts: 1, payload: .modelLoadStart(.init(modelId: "m"))))
            XCTFail("unexpected run id must be denied")
        } catch {
            XCTAssertEqual(error as? SessionRouterError, .unexpectedRunID("surprise"))
        }

        let bounded = SessionEventRouter(
            directory: directory, host: .stub, maxSessions: 1)
        try await bounded.route(
            envelope(runId: "first", ts: 1, payload: .modelLoadStart(.init(modelId: "m"))))
        do {
            try await bounded.route(
                envelope(runId: "second", ts: 2, payload: .modelLoadStart(.init(modelId: "m"))))
            XCTFail("session cap must be enforced")
        } catch {
            XCTAssertEqual(error as? SessionRouterError, .sessionLimitReached)
        }
    }
}
