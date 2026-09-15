import Foundation
import PolishCore
import PolishStore
import Testing

@Suite struct WebsiteSourcePersistenceTests {
    @Test func migrationReopenUpdateAndRetentionKeepOnlyTheWebsiteHost() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let location = Database.Location.file(directory.appendingPathComponent("website.sqlite3"))
        let old = try Database(location)
        try await Migrator.migrate(old, using: PolishSchema.migrations.filter { $0.version <= 3 })
        let oldID = UUID()
        _ = try await old.write { session in
            try session.run("INSERT INTO records (id,target_label,outcome,created_at,updated_at) VALUES (?,?,'failed',0,0)",
                            [SQLValue(oldID), .text("Google Chrome")])
        }
        let storage = try await PolishStorage.open(location)
        #expect(try await storage.records.record(oldID)?.website == nil)
        let website = try #require(WebsiteSource(url: URL(string: "https://mail.google.com/private?token=secret#draft")!))
        var record = PolishRecord(targetLabel: "Google Chrome", website: website,
                                  originalText: "合成草稿", outcome: .waiting,
                                  createdAt: Date(timeIntervalSince1970: 1000), updatedAt: Date(timeIntervalSince1970: 2000))
        try await storage.records.save(record)
        record.outcome = .failed
        record.failure = .requestIncomplete
        try await storage.records.save(record)
        let reopened = try await PolishStorage.open(location)
        #expect(try await reopened.records.record(record.id) == record)
        let db = try Database(location)
        let hosts = try await db.read { try $0.query("SELECT website_host FROM records WHERE website_host IS NOT NULL") { try $0.text("website_host") } }
        #expect(hosts == ["mail.google.com"])
        _ = try await reopened.records.purge(RetentionPolicy(textMaxAge: 0), now: Date())
        let cleared = try #require(try await reopened.records.record(record.id))
        #expect(cleared.originalText == nil)
        #expect(cleared.website == website)
        #expect(cleared.targetLabel == "Google Chrome")
    }

    @Test func rejectsAFullURLInThePersistedHostColumn() async throws {
        let store = try await PolishStorage.open(.memory)
        let db = store.database
        let id = UUID()
        _ = try await db.write { session in
            try session.run("INSERT INTO records (id,target_label,outcome,website_host,created_at,updated_at) VALUES (?,?,'failed',?,0,0)",
                            [SQLValue(id), .text("Safari"), .text("https://example.com/private")])
        }
        // Decode through the public repository, using the same database connection.
        await #expect(throws: PersistenceError.decoding("website_host")) { try await store.records.record(id) }
    }
}
