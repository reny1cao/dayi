import Foundation
import PolishCore
import PolishStore
import Testing
@testable import TextPolishApp

private func temporaryFile() throws -> Database.Location {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                            attributes: [.posixPermissions: 0o700])
    return .file(directory.appendingPathComponent("dayi.sqlite3"))
}

/// Ages are relative to now because `attach` purges against the real clock. Whole seconds
/// keep the millisecond column lossless.
private func record(_ outcome: Outcome, age: TimeInterval = 0, text: String? = "草稿") -> PolishRecord {
    let moment = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 - age).rounded())
    return PolishRecord(targetLabel: "Chrome", originalText: text, resultText: "结果",
                        outcome: outcome, createdAt: moment, updatedAt: moment)
}

/// Every operation fails, which is what a database on a full or read-only volume looks like.
private struct FailingRecordStore: RecordStore {
    func save(_ record: PolishRecord) throws { throw PersistenceError.busy }
    func record(_ id: UUID) throws -> PolishRecord? { throw PersistenceError.busy }
    func recent(limit: Int) throws -> [PolishRecord] { throw PersistenceError.busy }
    func delete(_ id: UUID) throws { throw PersistenceError.busy }
    func purge(_ policy: RetentionPolicy, now: Date) throws -> PurgeReport { throw PersistenceError.busy }
    func usage(since: Date) throws -> [SkillUsage] { throw PersistenceError.busy }
}

/// Holds the first write open long enough that an unordered implementation would finish the
/// second one first and leave the older state on disk.
private actor DelayingRecordStore: RecordStore {
    private let inner = MemoryRecordStore()
    private var delayed = false

    func save(_ record: PolishRecord) async throws {
        if !delayed {
            delayed = true
            try? await Task.sleep(for: .milliseconds(80))
        }
        try await inner.save(record)
    }

    func record(_ id: UUID) async throws -> PolishRecord? { try await inner.record(id) }
    func recent(limit: Int) async throws -> [PolishRecord] { try await inner.recent(limit: limit) }
    func delete(_ id: UUID) async throws { try await inner.delete(id) }
    func purge(_ policy: RetentionPolicy, now: Date) async throws -> PurgeReport {
        try await inner.purge(policy, now: now)
    }
    func usage(since: Date) async throws -> [SkillUsage] { try await inner.usage(since: since) }
}

@Suite @MainActor
struct PolishHistoryTests {
    @Test func aRecordWrittenBeforeTheDatabaseOpensIsNotLost() async throws {
        let history = PolishHistory()
        let early = record(.applied)
        history.save(early)
        #expect(history.records.map(\.id) == [early.id])
        #expect(!history.isReady)

        let store = MemoryRecordStore()
        await history.attach(store, purging: .unlimited)
        #expect(history.isReady)
        #expect(try await store.record(early.id)?.outcome == .applied)
    }

    @Test func attachingRestoresWhatAPreviousRunStored() async throws {
        let location = try temporaryFile()
        let first = PolishHistory()
        await first.attach(try await PolishStorage.open(location).records, purging: .unlimited)
        let earlier = record(.applied, age: 120)
        let later = record(.undone, age: 60)
        first.save(earlier)
        first.save(later)
        await first.settle()

        // A second run opens the same file and has to come back with the same history.
        let second = PolishHistory()
        await second.attach(try await PolishStorage.open(location).records, purging: .unlimited)
        #expect(second.records.map(\.id) == [later.id, earlier.id])
        #expect(second.records[0].outcome == .undone)
        #expect(second.records[1].originalText == "草稿")
    }

    @Test func anInterruptedAttemptIsRecoveredIntoAHonestState() async throws {
        let store = MemoryRecordStore()
        let running = record(.running)
        let writing = record(.applying)
        let finished = record(.applied)
        for entry in [running, writing, finished] { try await store.save(entry) }

        let history = PolishHistory()
        await history.attach(store, purging: .unlimited)

        // A request that never produced text failed; a write that was under way cannot be
        // proven either way, so it stays uncertain rather than being called a success.
        #expect(try await store.record(running.id)?.outcome == .failed)
        #expect(try await store.record(writing.id)?.outcome == .uncertain)
        #expect(try await store.record(finished.id)?.outcome == .applied)
        #expect(history.records.first { $0.id == writing.id }?.failure == .interrupted(wasWriting: true))
        let allFinal = history.records.allSatisfy { $0.outcome.isFinal }
        #expect(allFinal)
    }

    @Test func attachingAppliesTheRetentionPolicy() async throws {
        let store = MemoryRecordStore()
        try await store.save(record(.applied, age: 40 * 86_400))
        let recent = record(.applied, age: 3 * 86_400)
        try await store.save(recent)

        let history = PolishHistory()
        await history.attach(store, purging: RetentionPolicy(maxAge: 30 * 86_400, textMaxAge: 2 * 86_400))
        #expect(history.records.map(\.id) == [recent.id])
        #expect(history.records[0].originalText == nil)
    }

    @Test func twoUpdatesToOneJobLandInTheOrderTheyWereMade() async throws {
        let store = DelayingRecordStore()
        let history = PolishHistory()
        await history.attach(store, purging: .unlimited)
        var entry = record(.running)
        history.save(entry)
        entry.outcome = .applied
        history.save(entry)
        await history.settle()
        #expect(try await store.record(entry.id)?.outcome == .applied)
        #expect(history.records.count == 1)
    }

    @Test func removingAndClearingReachTheStore() async throws {
        let store = MemoryRecordStore()
        let history = PolishHistory()
        await history.attach(store, purging: .unlimited)
        let kept = record(.applied)
        let dropped = record(.failed)
        history.save(kept)
        history.save(dropped)
        history.remove(dropped.id)
        await history.settle()
        #expect(history.records.map(\.id) == [kept.id])
        #expect(try await store.record(dropped.id) == nil)

        history.clear()
        await history.settle()
        #expect(history.records.isEmpty)
        #expect(try await store.recent(limit: 10).isEmpty)
    }

    @Test func aStoreThatCannotBeWrittenIsReportedAndNeverThrows() async throws {
        let history = PolishHistory()
        await history.attach(FailingRecordStore(), purging: .unlimited)
        #expect(!history.isReady)
        #expect(history.failure != nil)

        // The list still works; only its durability is gone.
        let entry = record(.applied)
        history.save(entry)
        await history.settle()
        #expect(history.records.map(\.id) == [entry.id])
    }

    @Test func openingTwiceKeepsOneBuiltInSkill() async throws {
        let location = try temporaryFile()
        let first = try await PolishStorageBootstrap.open(location)
        let second = try await PolishStorageBootstrap.open(location)
        #expect(first.skillID == second.skillID)

        let skills = try await PolishStorage.open(location).skills
        let active = try await skills.skills(includingArchived: false)
        #expect(active.count == 1)
        #expect(active[0].isBuiltIn)
        #expect(active[0].sourceVersion == "dayi-default-1")
        #expect(try await skills.skills(includingArchived: true).count == 1)
    }

    @Test func newDefaultArchivesPreviousSkillWithoutRewritingHistory() async throws {
        let location = try temporaryFile()
        let storage = try await PolishStorage.open(location)
        let previous = Skill(name: "Previous default", systemPrompt: "Synthetic old instructions",
                             userPromptTemplate: "Old draft: {input}", sourceVersion: "5.5.3", isBuiltIn: true)
        let custom = Skill(name: "My skill", systemPrompt: "Custom", userPromptTemplate: "{input}", sourceVersion: "custom-1")
        try await storage.skills.save(previous)
        try await storage.skills.save(custom)
        let oldRecord = PolishRecord(skillID: previous.id, targetLabel: "Synthetic App",
                                     originalText: "原稿", resultText: "历史结果", outcome: .applied)
        try await storage.records.save(oldRecord)
        let savedRecord = try await storage.records.record(oldRecord.id)
        let savedCustom = try await storage.skills.skill(custom.id)

        let opened = try await PolishStorageBootstrap.open(location)
        #expect(opened.skillID != previous.id)
        let currentID = try #require(opened.skillID)
        let current = try #require(try await storage.skills.skill(currentID))
        #expect(current.sourceVersion == "dayi-default-1")
        #expect(current.systemPrompt == (try PromptTemplate.bundled()).systemPrompt)
        let archived = try #require(try await storage.skills.skill(previous.id))
        #expect(archived.archivedAt != nil)
        #expect(archived.systemPrompt == previous.systemPrompt)
        #expect(archived.userPromptTemplate == previous.userPromptTemplate)
        #expect(try await storage.records.record(oldRecord.id) == savedRecord)
        #expect(try await storage.skills.skill(custom.id) == savedCustom)
        #expect(try await PolishStorageBootstrap.open(location).skillID == current.id)
        #expect(try await storage.skills.skills(includingArchived: true).count == 3)
    }

    @Test func aStoredJobKeepsItsSkillAndText() async throws {
        let location = try temporaryFile()
        let opened = try await PolishStorageBootstrap.open(location)
        let history = PolishHistory()
        await history.attach(opened.records, purging: .unlimited)
        let entry = PolishRecord(skillID: opened.skillID, targetLabel: "Chrome",
                                 originalText: "e\u{0301}🙂", resultText: "结果", outcome: .applied)
        history.save(entry)
        await history.settle()

        let reopened = try await PolishStorage.open(location)
        let stored = try #require(try await reopened.records.record(entry.id))
        #expect(stored.skillID == opened.skillID)
        #expect(stored.originalText!.utf16.elementsEqual("e\u{0301}🙂".utf16))
        let usage = try await reopened.records.usage(since: Date(timeIntervalSince1970: 0))
        #expect(usage.map(\.skillID) == [opened.skillID])
        #expect(usage[0].applied == 1)
    }
}
