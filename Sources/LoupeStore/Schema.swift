import GRDB

/// One SQLite file per session; migrations are append-only.
/// `ts_ns` columns store UInt64 nanoseconds as Int64 bit patterns (SQLite
/// integers are signed); ordering diverges only past 2^63 ns ≈ 292 years.
enum LoupeSchema {
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try db.create(table: "runs") { t in
                t.column("id", .text).primaryKey()
                t.column("started_at_ns", .integer).notNull()
                t.column("ended_at_ns", .integer)
                t.column("host_fingerprint", .text).notNull()
                t.column("spec", .text)
            }

            // Separate tables for the same reason they are separate model
            // types: the two signal families must not mix.
            try db.create(table: "system_samples") { t in
                t.column("run_id", .text).notNull().references("runs", onDelete: .cascade)
                t.column("ts_ns", .integer).notNull()
                t.column("thermal_state", .text).notNull()
                t.column("memory_used_bytes", .integer).notNull()
                t.column("memory_free_bytes", .integer).notNull()
                t.column("swap_used_bytes", .integer).notNull()
                t.column("gpu_busy_percent", .double)
                t.column("gpu_power_mw", .double)
                t.column("ane_power_mw", .double)
                t.column("package_power_mw", .double)
            }
            try db.create(indexOn: "system_samples", columns: ["run_id", "ts_ns"])

            try db.create(table: "process_samples") { t in
                t.column("run_id", .text).notNull().references("runs", onDelete: .cascade)
                t.column("ts_ns", .integer).notNull()
                t.column("pid", .integer).notNull()
                t.column("cpu_percent", .double).notNull()
                t.column("rss_bytes", .integer).notNull()
            }
            try db.create(indexOn: "process_samples", columns: ["run_id", "ts_ns"])

            try db.create(table: "inference_events") { t in
                t.column("run_id", .text).notNull()
                t.column("ts_ns", .integer).notNull()
                t.column("request_id", .text)
                t.column("event", .text).notNull()
                t.column("payload", .text).notNull()
            }
            try db.create(indexOn: "inference_events", columns: ["run_id", "ts_ns"])
        }

        return migrator
    }
}
