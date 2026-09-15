import Foundation

/// One ordered, irreversible step from schema version n-1 to n. A migration is data as well
/// as DDL, so it takes a session rather than a list of strings.
public struct Migration: Sendable {
    public let version: Int32
    public let apply: @Sendable (Session) throws -> Void

    public init(version: Int32, apply: @escaping @Sendable (Session) throws -> Void) {
        self.version = version
        self.apply = apply
    }

    public init(version: Int32, statements: String) {
        self.init(version: version) { session in try session.execute(statements) }
    }
}

public enum Migrator {
    /// Applies every migration newer than the file's own version, each in its own
    /// transaction, and returns the version the file ends on. Interrupted halfway, the file
    /// is left on the last version that fully committed, never on a partial one.
    @discardableResult
    public static func migrate(_ database: Database, using migrations: [Migration]) async throws -> Int32 {
        let ordered = migrations.sorted { $0.version < $1.version }
        precondition(Set(ordered.map(\.version)).count == ordered.count, "migration versions must be unique")
        guard let latest = ordered.last?.version else { return try await database.userVersion() }
        let current = try await database.userVersion()
        // An older build must not write through a newer build's schema: the columns it does
        // not know about are exactly the ones it would silently drop on an update.
        guard current <= latest else { throw PersistenceError.schemaTooNew(found: current, supported: latest) }
        for migration in ordered where migration.version > current {
            do {
                try await database.write { session in
                    try migration.apply(session)
                    // user_version lives in the file header and is part of this transaction,
                    // so the version and the schema can never disagree.
                    try session.execute("PRAGMA user_version = \(migration.version)")
                }
            } catch {
                let reason = (error as? PersistenceError)?.errorDescription ?? "\(error)"
                throw PersistenceError.migrationFailed(version: migration.version, reason: reason)
            }
        }
        return latest
    }
}

/// The application's own schema. Versions are append-only: a released version is never
/// edited, because the files it already created cannot be edited with it.
public enum PolishSchema {
    public static let migrations: [Migration] = [
        Migration(version: 1, statements: """
            CREATE TABLE skills (
                id TEXT PRIMARY KEY NOT NULL,
                -- SQLite's one-argument trim only removes spaces, so the other blanks a
                -- person would call empty are named explicitly.
                name TEXT NOT NULL CHECK (length(trim(name, char(32, 9, 10, 13))) > 0),
                system_prompt TEXT NOT NULL,
                user_prompt_template TEXT NOT NULL CHECK (instr(user_prompt_template, '{input}') > 0),
                source_version TEXT NOT NULL,
                is_built_in INTEGER NOT NULL DEFAULT 0 CHECK (is_built_in IN (0, 1)),
                created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL,
                archived_at INTEGER
            ) STRICT;

            CREATE UNIQUE INDEX skills_active_name ON skills (name) WHERE archived_at IS NULL;

            CREATE TABLE records (
                id TEXT PRIMARY KEY NOT NULL,
                skill_id TEXT REFERENCES skills (id) ON DELETE SET NULL,
                target_label TEXT NOT NULL,
                original_text TEXT,
                result_text TEXT,
                outcome TEXT NOT NULL CHECK (outcome IN
                    ('running', 'failed', 'waiting', 'applying', 'applied', 'uncertain', 'undone')),
                message TEXT,
                created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL
            ) STRICT;

            CREATE INDEX records_created_at ON records (created_at DESC);
            CREATE INDEX records_skill ON records (skill_id, created_at DESC);

            CREATE TABLE preferences (
                key TEXT PRIMARY KEY NOT NULL,
                value TEXT NOT NULL,
                updated_at INTEGER NOT NULL
            ) STRICT;
            """),
        // Which model answered. Older rows stay NULL rather than being guessed.
        Migration(version: 2, statements: "ALTER TABLE records ADD COLUMN model TEXT"),
        // Old rows retain their original message. New known failures can change display language.
        Migration(version: 3, statements: "ALTER TABLE records ADD COLUMN failure_json TEXT"),
        // Only the captured website host is retained; older rows remain unclassified.
        Migration(version: 4, statements: "ALTER TABLE records ADD COLUMN website_host TEXT"),
    ]

    public static let version = migrations.map(\.version).max() ?? 0
}
