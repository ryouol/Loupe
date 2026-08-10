import Foundation
import LoupeCore

/// Fans incoming adapter events out to one SessionStore per runId, batching
/// inserts so a 100+ events/sec decode stream doesn't pay per-row
/// transaction costs. The daemon owns one of these behind its socket server.
public actor SessionEventRouter {
    private let directory: URL
    private let host: HostFingerprint
    private let flushThreshold: Int
    private var stores: [String: SessionStore] = [:]
    private var pending: [String: [EventEnvelope]] = [:]

    public init(directory: URL, host: HostFingerprint, flushThreshold: Int = 200) {
        self.directory = directory
        self.host = host
        self.flushThreshold = flushThreshold
    }

    public func route(_ envelope: EventEnvelope) async throws {
        _ = try store(for: envelope)
        pending[envelope.runId, default: []].append(envelope)
        let count = pending[envelope.runId]?.count ?? 0
        // request_end flushes eagerly so completed requests are durable and
        // queryable immediately, not stranded behind the batch threshold.
        if count >= flushThreshold || envelope.kind == .requestEnd {
            try await flush(runId: envelope.runId)
        }
    }

    public func flushAll() async throws {
        for runId in pending.keys {
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
        let store = try SessionStore(
            runId: envelope.runId, directory: directory,
            startedAtNs: envelope.ts, host: host)
        stores[envelope.runId] = store
        return store
    }
}
