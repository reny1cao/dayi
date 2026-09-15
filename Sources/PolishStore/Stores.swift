import Foundation
import PolishCore

/// The persistence abstraction the rest of the app depends on. It is expressed in domain
/// terms, not in SQL terms, so the SQLite implementation below and the in-memory one are
/// interchangeable and the app never learns which one it has.
public protocol SkillStore: Sendable {
    /// Inserts or replaces by identity. Callers own the timestamps: a save is not a "touch".
    func save(_ skill: Skill) async throws
    func skill(_ id: UUID) async throws -> Skill?
    func skills(includingArchived: Bool) async throws -> [Skill]
    func archive(_ id: UUID, at date: Date) async throws
    /// Removes the skill; records that used it keep their text and lose the link.
    func delete(_ id: UUID) async throws
}

public protocol RecordStore: Sendable {
    func save(_ record: PolishRecord) async throws
    func record(_ id: UUID) async throws -> PolishRecord?
    func recent(limit: Int) async throws -> [PolishRecord]
    func delete(_ id: UUID) async throws
    /// Applies the whole policy as one unit: a caller never sees half a purge.
    @discardableResult
    func purge(_ policy: RetentionPolicy, now: Date) async throws -> PurgeReport
    func usage(since: Date) async throws -> [SkillUsage]
}

public protocol PreferenceStore: Sendable {
    func value(forKey key: String) async throws -> String?
    func set(_ value: String?, forKey key: String) async throws
}

// MARK: - SQLite implementations

public struct SQLiteSkillStore: SkillStore {
    let database: Database

    public func save(_ skill: Skill) async throws {
        try await database.write { session in
            _ = try session.run("""
                INSERT INTO skills (id, name, system_prompt, user_prompt_template, source_version,
                                    is_built_in, created_at, updated_at, archived_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT (id) DO UPDATE SET
                    name = excluded.name,
                    system_prompt = excluded.system_prompt,
                    user_prompt_template = excluded.user_prompt_template,
                    source_version = excluded.source_version,
                    is_built_in = excluded.is_built_in,
                    updated_at = excluded.updated_at,
                    archived_at = excluded.archived_at
                """, [SQLValue(skill.id), .text(skill.name), .text(skill.systemPrompt),
                      .text(skill.userPromptTemplate), .text(skill.sourceVersion),
                      SQLValue(skill.isBuiltIn), SQLValue(skill.createdAt),
                      SQLValue(skill.updatedAt), SQLValue(skill.archivedAt)])
        }
    }

    public func skill(_ id: UUID) async throws -> Skill? {
        try await database.read { session in
            try session.query("SELECT * FROM skills WHERE id = ?", [SQLValue(id)], row: Skill.init(row:)).first
        }
    }

    public func skills(includingArchived: Bool = false) async throws -> [Skill] {
        let filter = includingArchived ? "" : "WHERE archived_at IS NULL"
        return try await database.read { session in
            try session.query("SELECT * FROM skills \(filter) ORDER BY name", row: Skill.init(row:))
        }
    }

    public func archive(_ id: UUID, at date: Date) async throws {
        try await database.write { session in
            _ = try session.run("UPDATE skills SET archived_at = ?, updated_at = ? WHERE id = ?",
                            [SQLValue(date), SQLValue(date), SQLValue(id)])
        }
    }

    public func delete(_ id: UUID) async throws {
        try await database.write { session in
            _ = try session.run("DELETE FROM skills WHERE id = ?", [SQLValue(id)])
        }
    }
}

public struct SQLiteRecordStore: RecordStore {
    let database: Database

    public func save(_ record: PolishRecord) async throws {
        try await database.write { session in
            _ = try session.run("""
                INSERT INTO records (id, skill_id, target_label, model, original_text, result_text,
                                     outcome, message, failure_json, website_host, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT (id) DO UPDATE SET
                    skill_id = excluded.skill_id,
                    target_label = excluded.target_label,
                    model = excluded.model,
                    original_text = excluded.original_text,
                    result_text = excluded.result_text,
                    outcome = excluded.outcome,
                    message = excluded.message,
                    failure_json = excluded.failure_json,
                    website_host = excluded.website_host,
                    updated_at = excluded.updated_at
                """, [SQLValue(record.id), SQLValue(record.skillID), .text(record.targetLabel), SQLValue(record.model),
                      SQLValue(record.originalText), SQLValue(record.resultText),
                      .text(record.outcome.rawValue), SQLValue(record.message),
                      SQLValue(try record.failure.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }),
                      SQLValue(record.website?.host),
                      SQLValue(record.createdAt), SQLValue(record.updatedAt)])
        }
    }

    public func record(_ id: UUID) async throws -> PolishRecord? {
        try await database.read { session in
            try session.query("SELECT * FROM records WHERE id = ?", [SQLValue(id)], row: PolishRecord.init(row:)).first
        }
    }

    public func recent(limit: Int) async throws -> [PolishRecord] {
        guard limit > 0 else { return [] }
        return try await database.read { session in
            // The id breaks ties so that two records written in the same millisecond keep a
            // stable order between calls, which paging and purging both depend on.
            try session.query("SELECT * FROM records ORDER BY created_at DESC, id DESC LIMIT ?",
                              [SQLValue(limit)], row: PolishRecord.init(row:))
        }
    }

    public func delete(_ id: UUID) async throws {
        try await database.write { session in
            _ = try session.run("DELETE FROM records WHERE id = ?", [SQLValue(id)])
        }
    }

    @discardableResult
    public func purge(_ policy: RetentionPolicy, now: Date = Date()) async throws -> PurgeReport {
        try await database.write { session in
            var deleted = 0
            if let maxAge = policy.maxAge {
                deleted += try session.run("DELETE FROM records WHERE created_at < ?",
                                           [SQLValue(now.addingTimeInterval(-maxAge))])
            }
            if let maxCount = policy.maxCount {
                deleted += try session.run("""
                    DELETE FROM records WHERE id NOT IN (
                        SELECT id FROM records ORDER BY created_at DESC, id DESC LIMIT ?
                    )
                    """, [SQLValue(max(maxCount, 0))])
            }
            var blanked = 0
            if let textMaxAge = policy.textMaxAge {
                // Blanking runs after deletion so a row is never blanked and then removed,
                // which would report the same record under both counters.
                blanked = try session.run("""
                    UPDATE records SET original_text = NULL, result_text = NULL, updated_at = ?
                    WHERE created_at < ? AND (original_text IS NOT NULL OR result_text IS NOT NULL)
                    """, [SQLValue(now), SQLValue(now.addingTimeInterval(-textMaxAge))])
            }
            return PurgeReport(deletedRows: deleted, blankedTexts: blanked)
        }
    }

    public func usage(since: Date) async throws -> [SkillUsage] {
        try await database.read { session in
            try session.query("""
                SELECT skill_id,
                       COUNT(*) AS total,
                       SUM(CASE WHEN outcome = 'applied' THEN 1 ELSE 0 END) AS applied,
                       MAX(created_at) AS last_used_at
                FROM records
                WHERE skill_id IS NOT NULL AND created_at >= ?
                GROUP BY skill_id
                ORDER BY total DESC, last_used_at DESC
                """, [SQLValue(since)]) { row in
                SkillUsage(skillID: try row.uuid("skill_id"),
                           total: Int(try row.integer("total")),
                           applied: Int(try row.integer("applied")),
                           lastUsedAt: try row.date("last_used_at"))
            }
        }
    }
}

public struct SQLitePreferenceStore: PreferenceStore {
    let database: Database

    public func value(forKey key: String) async throws -> String? {
        try await database.read { session in
            try session.query("SELECT value FROM preferences WHERE key = ?", [.text(key)]) { row in
                try row.text("value")
            }.first
        }
    }

    /// A nil value removes the key, so "unset" and "set to empty" stay distinguishable.
    public func set(_ value: String?, forKey key: String) async throws {
        try await database.write { session in
            guard let value else {
                _ = try session.run("DELETE FROM preferences WHERE key = ?", [.text(key)])
                return
            }
            _ = try session.run("""
                INSERT INTO preferences (key, value, updated_at) VALUES (?, ?, ?)
                ON CONFLICT (key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at
                """, [.text(key), .text(value), SQLValue(Date())])
        }
    }
}

// MARK: - Composition root

/// Opens the file, brings it to the current schema, and hands back the three stores. It is
/// the only place that knows all of them, so nothing else has to learn the open sequence.
public struct PolishStorage: Sendable {
    public let database: Database
    public let skills: SQLiteSkillStore
    public let records: SQLiteRecordStore
    public let preferences: SQLitePreferenceStore

    public static func open(_ location: Database.Location,
                            migrations: [Migration] = PolishSchema.migrations) async throws -> PolishStorage {
        let database = try Database(location)
        try await Migrator.migrate(database, using: migrations)
        return PolishStorage(database: database, skills: SQLiteSkillStore(database: database),
                             records: SQLiteRecordStore(database: database),
                             preferences: SQLitePreferenceStore(database: database))
    }
}

// MARK: - Row decoding

extension Skill {
    init(row: Row) throws {
        self.init(id: try row.uuid("id"), name: try row.text("name"),
                  systemPrompt: try row.text("system_prompt"),
                  userPromptTemplate: try row.text("user_prompt_template"),
                  sourceVersion: try row.text("source_version"),
                  isBuiltIn: try row.bool("is_built_in"),
                  createdAt: try row.date("created_at"), updatedAt: try row.date("updated_at"),
                  archivedAt: try row.optionalDate("archived_at"))
    }
}

extension PolishRecord {
    init(row: Row) throws {
        guard let outcome = Outcome(rawValue: try row.text("outcome")) else {
            throw PersistenceError.decoding("outcome")
        }
        let failure: RecordedFailure?
        if let json = try row.optionalText("failure_json") {
            do { failure = try JSONDecoder().decode(RecordedFailure.self, from: Data(json.utf8)) }
            catch { throw PersistenceError.decoding("failure_json") }
        } else { failure = nil }
        let website: WebsiteSource?
        if let host = try row.optionalText("website_host") {
            guard let source = WebsiteSource(host: host) else { throw PersistenceError.decoding("website_host") }
            website = source
        } else { website = nil }
        self.init(id: try row.uuid("id"), skillID: try row.optionalUUID("skill_id"),
                  targetLabel: try row.text("target_label"), model: try row.optionalText("model"),
                  website: website,
                  originalText: try row.optionalText("original_text"),
                  resultText: try row.optionalText("result_text"),
                  outcome: outcome, message: try row.optionalText("message"),
                  failure: failure,
                  createdAt: try row.date("created_at"), updatedAt: try row.date("updated_at"))
    }
}

// MARK: - In-memory implementation

/// The same contract without a file. It is what "keep nothing on disk" selects at runtime,
/// and it is the second implementation that keeps the protocol honest: anything the SQLite
/// store can do that this cannot has leaked SQL into the abstraction.
public actor MemoryRecordStore: RecordStore {
    private var storage: [UUID: PolishRecord] = [:]

    public init() {}

    public func save(_ record: PolishRecord) { storage[record.id] = record }
    public func record(_ id: UUID) -> PolishRecord? { storage[id] }
    public func delete(_ id: UUID) { storage[id] = nil }

    public func recent(limit: Int) -> [PolishRecord] {
        guard limit > 0 else { return [] }
        return Array(sortedNewestFirst().prefix(limit))
    }

    @discardableResult
    public func purge(_ policy: RetentionPolicy, now: Date = Date()) -> PurgeReport {
        var deleted = 0
        if let maxAge = policy.maxAge {
            let cutoff = now.addingTimeInterval(-maxAge)
            let expired = storage.values.filter { $0.createdAt < cutoff }
            expired.forEach { storage[$0.id] = nil }
            deleted += expired.count
        }
        if let maxCount = policy.maxCount {
            let survivors = Set(sortedNewestFirst().prefix(max(maxCount, 0)).map(\.id))
            let removed = storage.keys.filter { !survivors.contains($0) }
            removed.forEach { storage[$0] = nil }
            deleted += removed.count
        }
        var blanked = 0
        if let textMaxAge = policy.textMaxAge {
            let cutoff = now.addingTimeInterval(-textMaxAge)
            for record in storage.values where record.createdAt < cutoff
                && (record.originalText != nil || record.resultText != nil) {
                var stripped = record
                stripped.originalText = nil
                stripped.resultText = nil
                stripped.updatedAt = now
                storage[record.id] = stripped
                blanked += 1
            }
        }
        return PurgeReport(deletedRows: deleted, blankedTexts: blanked)
    }

    public func usage(since: Date) -> [SkillUsage] {
        let grouped = Dictionary(grouping: storage.values.filter { $0.skillID != nil && $0.createdAt >= since }) {
            $0.skillID!
        }
        return grouped.map { skillID, records in
            SkillUsage(skillID: skillID, total: records.count,
                       applied: records.filter { $0.outcome == .applied }.count,
                       lastUsedAt: records.map(\.createdAt).max() ?? since)
        }.sorted { ($0.total, $0.lastUsedAt) > ($1.total, $1.lastUsedAt) }
    }

    private func sortedNewestFirst() -> [PolishRecord] {
        storage.values.sorted {
            ($0.createdAt, $0.id.uuidString) > ($1.createdAt, $1.id.uuidString)
        }
    }
}
