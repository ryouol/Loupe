import Foundation
import GRDB
import LoupeCore

public enum StoreError: Error, Equatable {
    /// Inserts validate, so a row failing to decode means on-disk corruption.
    case corruptEventRow(String)
}

public struct RunRow: Sendable, Equatable {
    public let id: String
    public let startedAtNs: UInt64
    public let endedAtNs: UInt64?
    public let host: HostFingerprint
}

/// One session, one SQLite file, one actor.
public actor SessionStore {
    public nonisolated let runId: String
    public nonisolated let databaseURL: URL
    private let pool: DatabasePool

    public static func defaultDirectory() throws -> URL {
        try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        .appendingPathComponent("Loupe/sessions", isDirectory: true)
    }

    /// Opens or creates `<directory>/<runId>.sqlite` and upserts the run row.
    public init(
        runId: String, directory: URL, startedAtNs: UInt64, host: HostFingerprint
    ) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.runId = runId
        self.databaseURL = directory.appendingPathComponent("\(runId).sqlite")
        // DatabasePool = WAL: one writer (daemon), many readers (GUI).
        self.pool = try DatabasePool(path: databaseURL.path)
        try LoupeSchema.migrator.migrate(pool)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let hostJSON = String(decoding: try encoder.encode(host), as: UTF8.self)
        let id = runId
        try pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO runs (id, started_at_ns, host_fingerprint) VALUES (?, ?, ?)
                    ON CONFLICT(id) DO NOTHING
                    """,
                arguments: [id, Int64(bitPattern: startedAtNs), hostJSON])
        }
    }

    public func end(atNs: UInt64) throws {
        let id = runId
        try pool.write { db in
            try db.execute(
                sql: "UPDATE runs SET ended_at_ns = ? WHERE id = ?",
                arguments: [Int64(bitPattern: atNs), id])
        }
    }

    public func run() throws -> RunRow? {
        let id = runId
        return try pool.read { db in
            guard
                let row = try Row.fetchOne(
                    db, sql: "SELECT * FROM runs WHERE id = ?", arguments: [id])
            else { return nil }
            let hostJSON: String = row["host_fingerprint"]
            let host = try JSONDecoder().decode(HostFingerprint.self, from: Data(hostJSON.utf8))
            let ended: Int64? = row["ended_at_ns"]
            return RunRow(
                id: row["id"],
                startedAtNs: UInt64(bitPattern: row["started_at_ns"]),
                endedAtNs: ended.map(UInt64.init(bitPattern:)),
                host: host)
        }
    }

    // MARK: - Inserts

    /// One transaction + cached statements — per-row transactions would blow
    /// the 2s/100k-row budget.
    public func append(samples: [SystemSample]) throws {
        let id = runId
        try pool.write { db in
            let systemStatement = try db.cachedStatement(
                sql: """
                    INSERT INTO system_samples
                    (run_id, ts_ns, thermal_state, memory_used_bytes, memory_free_bytes,
                     swap_used_bytes, gpu_busy_percent, gpu_power_mw, ane_power_mw, package_power_mw)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """)
            let processStatement = try db.cachedStatement(
                sql: """
                    INSERT INTO process_samples (run_id, ts_ns, pid, cpu_percent, rss_bytes)
                    VALUES (?, ?, ?, ?, ?)
                    """)
            for sample in samples {
                let system = sample.system
                try systemStatement.execute(arguments: [
                    id,
                    Int64(bitPattern: system.ts),
                    system.thermalState.rawValue,
                    Int64(bitPattern: system.memoryUsedBytes),
                    Int64(bitPattern: system.memoryFreeBytes),
                    Int64(bitPattern: system.swapUsedBytes),
                    system.gpuBusyPercent,
                    system.gpuPowerMilliwatts,
                    system.anePowerMilliwatts,
                    system.packagePowerMilliwatts,
                ])
                if let process = sample.process {
                    try processStatement.execute(arguments: [
                        id,
                        Int64(bitPattern: process.ts),
                        process.pid,
                        process.cpuPercent,
                        Int64(bitPattern: process.rssBytes),
                    ])
                }
            }
        }
    }

    public func append(events: [EventEnvelope]) throws {
        try pool.write { db in
            let statement = try db.cachedStatement(
                sql: """
                    INSERT INTO inference_events (run_id, ts_ns, request_id, event, payload)
                    VALUES (?, ?, ?, ?, ?)
                    """)
            for envelope in events {
                try statement.execute(arguments: [
                    envelope.runId,
                    Int64(bitPattern: envelope.ts),
                    envelope.requestId,
                    envelope.kind.rawValue,
                    try Self.payloadJSON(envelope.payload),
                ])
            }
        }
    }

    // MARK: - Queries

    public func systemSamples(in range: ClosedRange<UInt64>? = nil) throws -> [SystemWideSample] {
        let id = runId
        return try pool.read { db in
            try Row.fetchAll(
                db,
                sql:
                    "SELECT * FROM system_samples WHERE run_id = ? \(Self.rangeClause(range)) ORDER BY ts_ns",
                arguments: Self.rangeArguments(id, range)
            ).map { row in
                SystemWideSample(
                    ts: UInt64(bitPattern: row["ts_ns"]),
                    thermalState: ThermalState(rawValue: row["thermal_state"]) ?? .nominal,
                    memoryUsedBytes: UInt64(bitPattern: row["memory_used_bytes"]),
                    memoryFreeBytes: UInt64(bitPattern: row["memory_free_bytes"]),
                    swapUsedBytes: UInt64(bitPattern: row["swap_used_bytes"]),
                    gpuBusyPercent: row["gpu_busy_percent"],
                    gpuPowerMilliwatts: row["gpu_power_mw"],
                    anePowerMilliwatts: row["ane_power_mw"],
                    packagePowerMilliwatts: row["package_power_mw"])
            }
        }
    }

    public func processSamples(in range: ClosedRange<UInt64>? = nil) throws -> [ProcessSample] {
        let id = runId
        return try pool.read { db in
            try Row.fetchAll(
                db,
                sql:
                    "SELECT * FROM process_samples WHERE run_id = ? \(Self.rangeClause(range)) ORDER BY ts_ns",
                arguments: Self.rangeArguments(id, range)
            ).map { row in
                ProcessSample(
                    ts: UInt64(bitPattern: row["ts_ns"]),
                    pid: row["pid"],
                    cpuPercent: row["cpu_percent"],
                    rssBytes: UInt64(bitPattern: row["rss_bytes"]))
            }
        }
    }

    /// Rows rebuild through the protocol decoder, so corruption surfaces.
    public func events(in range: ClosedRange<UInt64>? = nil) throws -> [EventEnvelope] {
        let id = runId
        let decoder = EventLineDecoder()
        return try pool.read { db in
            try Row.fetchAll(
                db,
                sql:
                    "SELECT * FROM inference_events WHERE run_id = ? \(Self.rangeClause(range)) ORDER BY ts_ns",
                arguments: Self.rangeArguments(id, range)
            ).map { row in
                let payloadJSON: String = row["payload"]
                let requestId: String? = row["request_id"]
                var object: [String: Any] = [
                    "v": EventProtocol.version,
                    "ts": NSNumber(value: UInt64(bitPattern: row["ts_ns"] as Int64)),
                    "runId": row["run_id"] as String,
                    "event": row["event"] as String,
                    "payload": (try? JSONSerialization.jsonObject(with: Data(payloadJSON.utf8)))
                        ?? [String: Any](),
                ]
                if let requestId { object["requestId"] = requestId }
                guard let line = try? JSONSerialization.data(withJSONObject: object),
                    case .success(let envelope) = decoder.decode(line: line)
                else {
                    throw StoreError.corruptEventRow(payloadJSON)
                }
                return envelope
            }
        }
    }

    public func journalMode() throws -> String {
        try pool.read { db in
            try String.fetchOne(db, sql: "PRAGMA journal_mode") ?? "unknown"
        }
    }

    public func counts() throws -> (system: Int, process: Int, events: Int) {
        let id = runId
        return try pool.read { db in
            func count(_ table: String) throws -> Int {
                try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM \(table) WHERE run_id = ?", arguments: [id]) ?? 0
            }
            return (
                try count("system_samples"), try count("process_samples"),
                try count("inference_events")
            )
        }
    }

    // MARK: - Helpers

    private static func rangeClause(_ range: ClosedRange<UInt64>?) -> String {
        range == nil ? "" : "AND ts_ns BETWEEN ? AND ?"
    }

    private static func rangeArguments(
        _ runId: String, _ range: ClosedRange<UInt64>?
    ) -> StatementArguments {
        guard let range else { return [runId] }
        return [runId, Int64(bitPattern: range.lowerBound), Int64(bitPattern: range.upperBound)]
    }

    private static func payloadJSON(_ payload: EventPayload) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data: Data
        switch payload {
        case .sessionStart(let p): data = try encoder.encode(p)
        case .clockSync(let p): data = try encoder.encode(p)
        case .modelLoadStart(let p): data = try encoder.encode(p)
        case .modelLoadEnd(let p): data = try encoder.encode(p)
        case .requestStart(let p): data = try encoder.encode(p)
        case .prefillEnd(let p): data = try encoder.encode(p)
        case .decodeTick(let p): data = try encoder.encode(p)
        case .requestEnd(let p): data = try encoder.encode(p)
        case .error(let p): data = try encoder.encode(p)
        }
        return String(decoding: data, as: UTF8.self)
    }
}
