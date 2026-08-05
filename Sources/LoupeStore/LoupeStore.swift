import LoupeCore

/// SQLite persistence. The GRDB-backed schema, migrations, and queries land in
/// M0.5; this is a placeholder so the module exists and links.
public enum StorePlaceholder {
    /// Schema version, bumped by each migration. `0` means "no schema yet".
    public static let schemaVersion = 0
}
