import Foundation
import GRDB
import LoupeCore
import Darwin

public enum StoreError: LocalizedError, Equatable {
    /// Inserts validate, so a row failing to decode means on-disk corruption.
    case corruptEventRow(String)
    case unexpectedRunID(String)
    case unsafeDirectory(String)
    case invalidEvent
    case invalidSample
    case fileOperation(Int32)

    public var errorDescription: String? {
        switch self {
        case .corruptEventRow: return "Stored event data failed integrity validation."
        case .unexpectedRunID: return "An event did not match the active recording."
        case .unsafeDirectory:
            return "Loupe refused storage that is not an owner-controlled directory."
        case .invalidEvent: return "A runtime event failed protocol validation."
        case .invalidSample: return "A telemetry row failed semantic validation."
        case .fileOperation(let code):
            return "A local evidence file operation failed (POSIX \(code))."
        }
    }
}

public struct RunRow: Sendable, Equatable {
    public let id: String
    public let startedAtNs: UInt64
    public let endedAtNs: UInt64?
    public let host: HostFingerprint
}

/// One session, one SQLite file, one actor. Reads and writes run on GRDB's
/// own queues (async API), never blocking a cooperative-pool thread. The
/// app wires these under `~/Library/Application Support/Loupe/sessions/`.
public actor SessionStore {
    public nonisolated let storageID: UUID
    public nonisolated let runId: String
    public nonisolated let databaseURL: URL
    private let pool: DatabasePool

    /// Opens or creates `<directory>/<opaque UUID>.sqlite` and upserts the run
    /// row. Adapter-controlled run identifiers never become filesystem paths.
    public init(
        storageID: UUID = UUID(), runId: String, directory: URL,
        startedAtNs: UInt64, host: HostFingerprint
    ) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var directoryMetadata = stat()
        guard lstat(directory.path, &directoryMetadata) == 0,
            directoryMetadata.st_mode & S_IFMT == S_IFDIR,
            directoryMetadata.st_uid == geteuid()
        else { throw StoreError.unsafeDirectory(directory.path) }
        guard chmod(directory.path, S_IRWXU) == 0 else {
            throw StoreError.unsafeDirectory(directory.path)
        }
        guard lstat(directory.path, &directoryMetadata) == 0,
            directoryMetadata.st_mode & S_IFMT == S_IFDIR,
            directoryMetadata.st_uid == geteuid(),
            directoryMetadata.st_mode & 0o077 == 0
        else { throw StoreError.unsafeDirectory(directory.path) }

        self.storageID = storageID
        self.runId = runId
        self.databaseURL = directory.appendingPathComponent(
            "\(storageID.uuidString.lowercased()).sqlite")
        try Self.validateExistingDatabaseNodes(at: databaseURL)
        try Self.createDatabaseFileIfNeeded(at: databaseURL)
        // DatabasePool = WAL: one app-owned recorder, concurrent UI reads.
        self.pool = try DatabasePool(path: databaseURL.path)
        try LoupeSchema.migrator.migrate(pool)

        let hostJSON = String(
            decoding: try JSONEncoder.deterministic().encode(host), as: UTF8.self)
        let id = runId
        try pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO runs (id, started_at_ns, host_fingerprint) VALUES (?, ?, ?)
                    ON CONFLICT(id) DO NOTHING
                    """,
                arguments: [id, Int64(bitPattern: startedAtNs), hostJSON])
        }
        try Self.hardenDatabaseFiles(at: databaseURL)
    }

    public func end(atNs: UInt64) async throws {
        let id = runId
        try await pool.write { db in
            try db.execute(
                sql: "UPDATE runs SET ended_at_ns = ? WHERE id = ?",
                arguments: [Int64(bitPattern: atNs), id])
        }
        try Self.hardenDatabaseFiles(at: databaseURL)
    }

    public func run() async throws -> RunRow? {
        let id = runId
        return try await pool.read { db in
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
    public func append(samples: [SystemSample]) async throws {
        guard samples.allSatisfy(SystemSampleValidation.accepts) else {
            throw StoreError.invalidSample
        }
        let id = runId
        try await pool.write { db in
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
        try Self.hardenDatabaseFiles(at: databaseURL)
    }

    public func append(events: [EventEnvelope]) async throws {
        guard let unexpected = events.first(where: { $0.runId != runId }) else {
            let encoder = EventLineEncoder()
            let decoder = EventLineDecoder()
            for event in events {
                guard let line = try? encoder.encode(event),
                    case .success = decoder.decode(line: line)
                else { throw StoreError.invalidEvent }
            }
            return try await appendValidated(events: events)
        }
        throw StoreError.unexpectedRunID(unexpected.runId)
    }

    private func appendValidated(events: [EventEnvelope]) async throws {
        try await pool.write { db in
            let statement = try db.cachedStatement(
                sql: """
                    INSERT INTO inference_events (run_id, ts_ns, request_id, event, payload)
                    VALUES (?, ?, ?, ?, ?)
                    """)
            let encoder = JSONEncoder.deterministic()
            for envelope in events {
                try statement.execute(arguments: [
                    envelope.runId,
                    Int64(bitPattern: envelope.ts),
                    envelope.requestId,
                    envelope.kind.rawValue,
                    String(decoding: try encoder.encode(envelope.payload), as: UTF8.self),
                ])
            }
        }
        try Self.hardenDatabaseFiles(at: databaseURL)
    }

    // MARK: - Queries

    public func systemSamples(
        in range: ClosedRange<UInt64>? = nil
    ) async throws -> [SystemWideSample] {
        let id = runId
        return try await pool.read { db in
            try Row.fetchAll(
                db,
                sql:
                    "SELECT * FROM system_samples WHERE run_id = ? \(Self.rangeClause(range)) ORDER BY (ts_ns < 0), ts_ns, rowid",
                arguments: Self.rangeArguments(id, range)
            ).map { try Self.systemSample(from: $0) }
        }
    }

    public func processSamples(in range: ClosedRange<UInt64>? = nil) async throws -> [ProcessSample]
    {
        let id = runId
        return try await pool.read { db in
            try Row.fetchAll(
                db,
                sql:
                    "SELECT * FROM process_samples WHERE run_id = ? \(Self.rangeClause(range)) ORDER BY (ts_ns < 0), ts_ns, rowid",
                arguments: Self.rangeArguments(id, range)
            ).map { try Self.processSample(from: $0) }
        }
    }

    public func samples(in range: ClosedRange<UInt64>? = nil) async throws -> [SystemSample] {
        let id = runId
        return try await pool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT s.*,
                           p.pid AS process_pid,
                           p.cpu_percent AS process_cpu_percent,
                           p.rss_bytes AS process_rss_bytes
                    FROM system_samples s
                    LEFT JOIN process_samples p
                      ON p.run_id = s.run_id AND p.ts_ns = s.ts_ns
                    WHERE s.run_id = ? \(Self.rangeClause(range, column: "s.ts_ns"))
                    ORDER BY (s.ts_ns < 0), s.ts_ns, s.rowid
                    """,
                arguments: Self.rangeArguments(id, range)
            ).map { try Self.sample(from: $0) }
        }
    }

    /// Kind and payload validate on the way out, so corruption surfaces as a
    /// typed error instead of silently wrong data.
    public func events(in range: ClosedRange<UInt64>? = nil) async throws -> [EventEnvelope] {
        let id = runId
        let decoder = JSONDecoder()
        return try await pool.read { db in
            try Row.fetchAll(
                db,
                sql:
                    "SELECT * FROM inference_events WHERE run_id = ? \(Self.rangeClause(range)) ORDER BY (ts_ns < 0), ts_ns, rowid",
                arguments: Self.rangeArguments(id, range)
            ).map { try Self.event(from: $0, decoder: decoder) }
        }
    }

    public func journalMode() async throws -> String {
        try await pool.read { db in
            try String.fetchOne(db, sql: "PRAGMA journal_mode") ?? "unknown"
        }
    }

    public func counts() async throws -> (system: Int, process: Int, events: Int) {
        let id = runId
        return try await pool.read { db in
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

    /// Materializes the portable replay pair next to the opaque database.
    /// SQLite remains the durable source; the NDJSON pair is the inspectable,
    /// shareable evidence surface consumed by ReplayView.
    public func exportReplayPair(to directory: URL) async throws -> SessionFilePair {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.hardenOwnerDirectory(directory)
        let baseURL = directory.appendingPathComponent(storageID.uuidString.lowercased())
        let pair = SessionFilePair(basePath: baseURL.path)
        let encoder = JSONEncoder.deterministic()
        let eventTemporaryURL = directory.appendingPathComponent(
            ".\(UUID().uuidString.lowercased()).events.tmp")
        let sampleTemporaryURL = directory.appendingPathComponent(
            ".\(UUID().uuidString.lowercased()).samples.tmp")
        var eventFD = try Self.createSecureFile(at: eventTemporaryURL)
        defer {
            if eventFD >= 0 { close(eventFD) }
            unlink(eventTemporaryURL.path)
        }
        var sampleFD = try Self.createSecureFile(at: sampleTemporaryURL)
        defer {
            if sampleFD >= 0 { close(sampleFD) }
            unlink(sampleTemporaryURL.path)
        }

        let eventOutput = eventFD
        let id = runId
        try await pool.read { db in
            let cursor = try Row.fetchCursor(
                db,
                sql:
                    "SELECT * FROM inference_events WHERE run_id = ? ORDER BY (ts_ns < 0), ts_ns, rowid",
                arguments: [id])
            let decoder = JSONDecoder()
            let lineEncoder = EventLineEncoder()
            while let row = try cursor.next() {
                let event = try Self.event(from: row, decoder: decoder)
                try Self.writeLine(try lineEncoder.encode(event), to: eventOutput)
            }
        }

        let sampleOutput = sampleFD
        try await pool.read { db in
            let cursor = try Row.fetchCursor(
                db,
                sql: """
                    SELECT s.*,
                           p.pid AS process_pid,
                           p.cpu_percent AS process_cpu_percent,
                           p.rss_bytes AS process_rss_bytes
                    FROM system_samples s
                    LEFT JOIN process_samples p
                      ON p.run_id = s.run_id AND p.ts_ns = s.ts_ns
                    WHERE s.run_id = ?
                    ORDER BY (s.ts_ns < 0), s.ts_ns, s.rowid
                    """,
                arguments: [id])
            while let row = try cursor.next() {
                try Self.writeLine(
                    try encoder.encode(Self.sample(from: row)), to: sampleOutput)
            }
        }

        guard fsync(eventFD) == 0, fsync(sampleFD) == 0 else {
            throw StoreError.fileOperation(errno)
        }
        guard close(eventFD) == 0 else { throw StoreError.fileOperation(errno) }
        eventFD = -1
        guard close(sampleFD) == 0 else { throw StoreError.fileOperation(errno) }
        sampleFD = -1
        guard rename(eventTemporaryURL.path, pair.eventsURL.path) == 0 else {
            throw StoreError.fileOperation(errno)
        }
        if rename(sampleTemporaryURL.path, pair.systemURL.path) != 0 {
            let code = errno
            // A replay pair is one evidence unit. Never leave a newly
            // published events file paired with missing or stale telemetry.
            unlink(pair.eventsURL.path)
            throw StoreError.fileOperation(code)
        }
        for url in [pair.eventsURL, pair.systemURL] {
            guard chmod(url.path, S_IRUSR | S_IWUSR) == 0 else {
                throw StoreError.unsafeDirectory(directory.path)
            }
        }
        return pair
    }

    // MARK: - Helpers

    private static func event(from row: Row, decoder: JSONDecoder) throws -> EventEnvelope {
        let eventName: String = row["event"]
        let payloadJSON: String = row["payload"]
        let requestId: String? = row["request_id"]
        guard let kind = EventKind(rawValue: eventName),
            let payloadObject = try? JSONSerialization.jsonObject(
                with: Data(payloadJSON.utf8)) as? [String: Any],
            Set(payloadObject.keys).isSubset(of: EventLineDecoder.allowedPayloadKeys(for: kind)),
            let payload = try? EventPayload.decode(
                kind: kind, from: Data(payloadJSON.utf8), using: decoder),
            !(kind.requiresRequestID && requestId == nil)
        else {
            throw StoreError.corruptEventRow("\(eventName): \(payloadJSON)")
        }
        let envelope = EventEnvelope(
            ts: UInt64(bitPattern: row["ts_ns"]),
            runId: row["run_id"],
            requestId: requestId,
            payload: payload)
        guard
            case .success(let validated) = EventLineDecoder().decode(
                line: try EventLineEncoder().encode(envelope))
        else { throw StoreError.corruptEventRow("\(eventName): semantic validation failed") }
        return validated
    }

    private static func sample(from row: Row) throws -> SystemSample {
        let system = try systemSample(from: row)
        let processPID: Int32? = row["process_pid"]
        let process = processPID.map { pid in
            ProcessSample(
                ts: system.ts,
                pid: pid,
                cpuPercent: row["process_cpu_percent"],
                rssBytes: UInt64(bitPattern: row["process_rss_bytes"]))
        }
        let sample = SystemSample(system: system, process: process)
        guard SystemSampleValidation.accepts(sample) else {
            throw StoreError.invalidSample
        }
        return sample
    }

    private static func systemSample(from row: Row) throws -> SystemWideSample {
        guard let thermalState = ThermalState(rawValue: row["thermal_state"]) else {
            throw StoreError.invalidSample
        }
        let system = SystemWideSample(
            ts: UInt64(bitPattern: row["ts_ns"]),
            thermalState: thermalState,
            memoryUsedBytes: UInt64(bitPattern: row["memory_used_bytes"]),
            memoryFreeBytes: UInt64(bitPattern: row["memory_free_bytes"]),
            swapUsedBytes: UInt64(bitPattern: row["swap_used_bytes"]),
            gpuBusyPercent: row["gpu_busy_percent"],
            gpuPowerMilliwatts: row["gpu_power_mw"],
            anePowerMilliwatts: row["ane_power_mw"],
            packagePowerMilliwatts: row["package_power_mw"])
        guard SystemSampleValidation.accepts(SystemSample(system: system, process: nil)) else {
            throw StoreError.invalidSample
        }
        return system
    }

    private static func processSample(from row: Row) throws -> ProcessSample {
        let process = ProcessSample(
            ts: UInt64(bitPattern: row["ts_ns"]),
            pid: row["pid"],
            cpuPercent: row["cpu_percent"],
            rssBytes: UInt64(bitPattern: row["rss_bytes"]))
        let placeholder = SystemWideSample(
            ts: process.ts, thermalState: .nominal, memoryUsedBytes: 0,
            memoryFreeBytes: 0, swapUsedBytes: 0)
        guard SystemSampleValidation.accepts(SystemSample(system: placeholder, process: process))
        else {
            throw StoreError.invalidSample
        }
        return process
    }

    private static func createSecureFile(at url: URL) throws -> Int32 {
        let descriptor = open(
            url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw StoreError.fileOperation(errno) }
        guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            let code = errno
            close(descriptor)
            unlink(url.path)
            throw StoreError.fileOperation(code)
        }
        return descriptor
    }

    private static func hardenOwnerDirectory(_ directory: URL) throws {
        var metadata = stat()
        guard lstat(directory.path, &metadata) == 0,
            metadata.st_mode & S_IFMT == S_IFDIR,
            metadata.st_uid == geteuid(),
            chmod(directory.path, S_IRWXU) == 0,
            lstat(directory.path, &metadata) == 0,
            metadata.st_mode & S_IFMT == S_IFDIR,
            metadata.st_uid == geteuid(),
            metadata.st_mode & 0o077 == 0
        else { throw StoreError.unsafeDirectory(directory.path) }
    }

    private static func writeLine(_ line: Data, to descriptor: Int32) throws {
        var framed = line
        framed.append(UInt8(ascii: "\n"))
        try framed.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(
                    descriptor, base.advanced(by: offset), raw.count - offset)
                if written > 0 {
                    offset += written
                } else if written < 0, errno == EINTR {
                    continue
                } else {
                    throw StoreError.fileOperation(errno)
                }
            }
        }
    }

    private static func rangeClause(
        _ range: ClosedRange<UInt64>?, column: String = "ts_ns"
    ) -> String {
        guard let range else { return "" }
        // UInt64 nanoseconds are persisted as Int64 bit patterns. A range
        // crossing 2^63 wraps in SQLite's signed ordering, so it is the union
        // of the positive tail and negative head rather than one BETWEEN.
        if range.lowerBound <= UInt64(Int64.max), range.upperBound > UInt64(Int64.max) {
            return "AND (\(column) >= ? OR \(column) <= ?)"
        }
        return "AND \(column) BETWEEN ? AND ?"
    }

    private static func rangeArguments(
        _ runId: String, _ range: ClosedRange<UInt64>?
    ) -> StatementArguments {
        guard let range else { return [runId] }
        return [runId, Int64(bitPattern: range.lowerBound), Int64(bitPattern: range.upperBound)]
    }

    private static func hardenDatabaseFiles(at databaseURL: URL) throws {
        for suffix in ["", "-wal", "-shm"] {
            let path = databaseURL.path + suffix
            var metadata = stat()
            if lstat(path, &metadata) == 0 {
                guard metadata.st_mode & S_IFMT == S_IFREG,
                    metadata.st_uid == geteuid(),
                    metadata.st_nlink == 1,
                    chmod(path, S_IRUSR | S_IWUSR) == 0
                else {
                    throw StoreError.unsafeDirectory(databaseURL.deletingLastPathComponent().path)
                }
            } else if errno != ENOENT {
                throw StoreError.unsafeDirectory(databaseURL.deletingLastPathComponent().path)
            }
        }
    }

    private static func createDatabaseFileIfNeeded(at databaseURL: URL) throws {
        var metadata = stat()
        if lstat(databaseURL.path, &metadata) == 0 { return }
        guard errno == ENOENT else {
            throw StoreError.unsafeDirectory(databaseURL.deletingLastPathComponent().path)
        }
        for suffix in ["-wal", "-shm"] {
            if lstat(databaseURL.path + suffix, &metadata) == 0 || errno != ENOENT {
                throw StoreError.unsafeDirectory(databaseURL.deletingLastPathComponent().path)
            }
        }

        let descriptor = open(
            databaseURL.path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw StoreError.fileOperation(errno)
        }
        defer { close(descriptor) }
        guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            let code = errno
            unlink(databaseURL.path)
            throw StoreError.fileOperation(code)
        }
    }

    private static func validateExistingDatabaseNodes(at databaseURL: URL) throws {
        for suffix in ["", "-wal", "-shm"] {
            let path = databaseURL.path + suffix
            var metadata = stat()
            if lstat(path, &metadata) == 0 {
                guard metadata.st_mode & S_IFMT == S_IFREG,
                    metadata.st_uid == geteuid(),
                    metadata.st_nlink == 1,
                    metadata.st_mode & 0o077 == 0
                else {
                    throw StoreError.unsafeDirectory(databaseURL.deletingLastPathComponent().path)
                }
            } else if errno != ENOENT {
                throw StoreError.unsafeDirectory(databaseURL.deletingLastPathComponent().path)
            }
        }
    }
}
