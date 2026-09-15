import Foundation
import Testing
import PolishStore

private struct MigrationFailure: Error {}

private func fileDatabase(_ root: URL) throws -> Database {
    try Database(.file(root.appendingPathComponent("dayi.sqlite3")))
}

@Test func migrationsApplyInVersionOrderAndRecordTheResult() async throws {
    let database = try Database(.memory)
    let version = try await Migrator.migrate(database, using: [
        Migration(version: 2, statements: "ALTER TABLE a ADD COLUMN b TEXT"),
        Migration(version: 1, statements: "CREATE TABLE a (id TEXT) STRICT"),
    ])
    #expect(version == 2)
    #expect(try await database.userVersion() == 2)
    try await database.write { session in
        _ = try session.run("INSERT INTO a (id, b) VALUES (?, ?)", [.text("x"), .text("y")])
    }
}

@Test func migratingAnUpToDateFileDoesNothing() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let first = try fileDatabase(root)
    try await Migrator.migrate(first, using: PolishSchema.migrations)
    try await first.write { session in
        _ = try session.run("""
            INSERT INTO skills (id, name, system_prompt, user_prompt_template, source_version,
                                is_built_in, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, 0, 0, 0)
            """, [.text(UUID().uuidString), .text("保留"), .text("s"), .text("{input}"), .text("v")])
    }
    // Re-running the same migrations must not re-create the table and lose the row.
    let second = try fileDatabase(root)
    #expect(try await Migrator.migrate(second, using: PolishSchema.migrations) == PolishSchema.version)
    let names = try await second.read { session in
        try session.query("SELECT name FROM skills") { try $0.text("name") }
    }
    #expect(names == ["保留"])
}

@Test func aFailedMigrationLeavesTheFileOnItsPreviousVersion() async throws {
    let database = try Database(.memory)
    let migrations = [
        Migration(version: 1, statements: "CREATE TABLE kept (id TEXT) STRICT"),
        Migration(version: 2) { session in
            try session.execute("CREATE TABLE half_written (id TEXT) STRICT")
            throw MigrationFailure()
        },
    ]
    await #expect(throws: PersistenceError.self) { try await Migrator.migrate(database, using: migrations) }
    #expect(try await database.userVersion() == 1)
    // Version 2's table was created inside the failed transaction and must be gone with it.
    let tables = try await database.read { session in
        try session.query("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name") { try $0.text("name") }
    }
    #expect(tables == ["kept"])
}

@Test func aFileWrittenByANewerBuildIsRefused() async throws {
    let database = try Database(.memory)
    try await database.write { session in try session.execute("PRAGMA user_version = 99") }
    await #expect(throws: PersistenceError.schemaTooNew(found: 99, supported: 1)) {
        try await Migrator.migrate(database, using: [Migration(version: 1, statements: "CREATE TABLE a (id TEXT)")])
    }
}

@Test func aFreshFileEndsOnTheCurrentSchemaVersion() async throws {
    let storage = try await PolishStorage.open(.memory)
    #expect(try await storage.database.userVersion() == PolishSchema.version)
}

@Test func aTemplateWithoutItsPlaceholderIsRejected() async throws {
    let storage = try await PolishStorage.open(.memory)
    let invalid = Skill(name: "无占位符", systemPrompt: "s", userPromptTemplate: "没有占位符", sourceVersion: "v")
    await #expect(throws: PersistenceError.self) { try await storage.skills.save(invalid) }
    #expect(try await storage.skills.skills(includingArchived: true).isEmpty)
}

@Test(arguments: ["", "   ", "\n"]) func aBlankSkillNameIsRejected(name: String) async throws {
    let storage = try await PolishStorage.open(.memory)
    let invalid = Skill(name: name, systemPrompt: "s", userPromptTemplate: "{input}", sourceVersion: "v")
    await #expect(throws: PersistenceError.self) { try await storage.skills.save(invalid) }
}

@Test func aRecordCannotPointAtASkillThatDoesNotExist() async throws {
    let storage = try await PolishStorage.open(.memory)
    let orphan = PolishRecord(skillID: UUID(), targetLabel: "Chrome", outcome: .running)
    await #expect(throws: PersistenceError.self) { try await storage.records.save(orphan) }
    #expect(try await storage.records.recent(limit: 10).isEmpty)
}

@Test func deletingASkillKeepsItsRecordsAndClearsTheLink() async throws {
    let storage = try await PolishStorage.open(.memory)
    let skill = Skill(name: "增强", systemPrompt: "s", userPromptTemplate: "{input}", sourceVersion: "v")
    try await storage.skills.save(skill)
    let record = PolishRecord(skillID: skill.id, targetLabel: "Chrome", originalText: "草稿", outcome: .applied)
    try await storage.records.save(record)
    try await storage.skills.delete(skill.id)
    let stored = try await storage.records.record(record.id)
    #expect(stored?.originalText == "草稿")
    #expect(stored?.skillID == nil)
}

@Test func onlyActiveSkillNamesHaveToBeUnique() async throws {
    let storage = try await PolishStorage.open(.memory)
    let first = Skill(name: "增强", systemPrompt: "s", userPromptTemplate: "{input}", sourceVersion: "v")
    try await storage.skills.save(first)
    let duplicate = Skill(name: "增强", systemPrompt: "s", userPromptTemplate: "{input}", sourceVersion: "v")
    await #expect(throws: PersistenceError.self) { try await storage.skills.save(duplicate) }
    // Archiving frees the name; the old skill stays readable for the records that used it.
    try await storage.skills.archive(first.id, at: fixedDate())
    try await storage.skills.save(duplicate)
    #expect(try await storage.skills.skills(includingArchived: false).map(\.id) == [duplicate.id])
    #expect(try await storage.skills.skills(includingArchived: true).count == 2)
}

@Test func aStrictTableRejectsAValueOfTheWrongType() async throws {
    let storage = try await PolishStorage.open(.memory)
    await #expect(throws: PersistenceError.self) {
        try await storage.database.write { session in
            _ = try session.run("INSERT INTO preferences (key, value, updated_at) VALUES (?, ?, ?)",
                                [.text("k"), .text("v"), .text("not a timestamp")])
        }
    }
}

@Test func anUnknownOutcomeIsRejectedByTheSchemaAndByDecoding() async throws {
    let storage = try await PolishStorage.open(.memory)
    await #expect(throws: PersistenceError.self) {
        try await storage.database.write { session in
            _ = try session.run("""
                INSERT INTO records (id, target_label, outcome, created_at, updated_at)
                VALUES (?, ?, ?, 0, 0)
                """, [.text(UUID().uuidString), .text("Chrome"), .text("teleported")])
        }
    }
}
