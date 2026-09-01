import Foundation
import LoupeCore

/// Fans incoming adapter events out to one SessionStore per runId, batching
/// inserts so a 100+ events/sec decode stream doesn't pay per-row
/// transaction costs. User-owned recording flows pin this router to one run.
public enum SessionRouterError: Error, Equatable {
    case unexpectedRunID(String)
    case sessionLimitReached
    case pendingLimitReached(String)
}

public actor SessionEventRouter {
    private let directory: URL
    private let host: HostFingerprint
    private let flushThreshold: Int
    private let acceptedRunID: String?
    private let maxSessions: Int
    private let maxPendingPerSession: Int
    private var stores: [String: SessionStore] = [:]
    private var pending: [String: [EventEnvelope]] = [:]

    public init(
        directory: URL, host: HostFingerprint, flushThreshold: Int = 200,
        acceptedRunID: String? = nil, maxSessions: Int = 8,
        maxPendingPerSession: Int = 4_096
    ) {
        self.directory = directory
        self.host = host
        self.flushThreshold = max(1, min(flushThreshold, maxPendingPerSession))
        self.acceptedRunID = acceptedRunID
        self.maxSessions = max(1, min(maxSessions, 64))
        self.maxPendingPerSession = max(1, min(maxPendingPerSession, 65_536))
    }

    public func route(_ envelope: EventEnvelope) async throws {
        if let acceptedRunID, envelope.runId != acceptedRunID {
            throw SessionRouterError.unexpectedRunID(envelope.runId)
        }
        _ = try store(for: envelope)
        guard (pending[envelope.runId]?.count ?? 0) < maxPendingPerSession else {
            throw SessionRouterError.pendingLimitReached(envelope.runId)
        }
        pending[envelope.runId, default: []].append(envelope)
        let count = pending[envelope.runId]?.count ?? 0
        // request_end flushes eagerly so completed requests are durable and
        // queryable immediately, not stranded behind the batch threshold.
        if count >= flushThreshold || envelope.kind == .requestEnd {
            try await flush(runId: envelope.runId)
        }
    }

    public func flushAll() async throws {
        // Snapshot keys before `flush` removes them. Iterating a live
        // Dictionary.Keys view while mutating its dictionary is invalid, and
        // the awaited write also permits new routes to enter this actor.
        for runId in Array(pending.keys) {
            try await flush(runId: runId)
        }
    }

    public func persistedStore(runId: String) -> SessionStore? {
        stores[runId]
    }

    private func flush(runId: String) async throws {
        guard let batch = pending.removeValue(forKey: runId), !batch.isEmpty,
            let store = stores[runId]
        else { return }
        do {
            try await store.append(events: batch)
        } catch {
            // A failed write (SQLite busy, disk full) must not lose the
            // batch: re-queue it ahead of anything routed during the await.
            pending[runId] = batch + (pending[runId] ?? [])
            throw error
        }
    }

    private func store(for envelope: EventEnvelope) throws -> SessionStore {
        if let existing = stores[envelope.runId] { return existing }
        guard stores.count < maxSessions else { throw SessionRouterError.sessionLimitReached }
        let store = try SessionStore(
            runId: envelope.runId, directory: directory,
            startedAtNs: envelope.ts, host: host)
        stores[envelope.runId] = store
        return store
    }
}
