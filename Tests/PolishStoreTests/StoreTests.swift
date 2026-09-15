import Foundation
import Testing
import PolishCore
import PolishStore

enum StoreKind: String, Sendable, CaseIterable { case sqlite, memory }

/// Two skills plus a record store, so the same expectations can run against the SQLite
/// implementation and the in-memory one. A behaviour only one of them has is a leak.
private struct Fixture {
    let records: any RecordStore
    let skillA: UUID
    let skillB: UUID
}

private func fixture(_ kind: StoreKind) async throws -> Fixture {
    let skillA = Skill(name: "增强", systemPrompt: "s", userPromptTemplate: "{input}", sourceVersion: "v")
    let skillB = Skill(name: "改写", systemPrompt: "s", userPromptTemplate: "{input}", sourceVersion: "v")
    switch kind {
    case .memory:
        return Fixture(records: MemoryRecordStore(), skillA: skillA.id, skillB: skillB.id)
    case .sqlite:
        let storage = try await PolishStorage.open(.memory)
        try await storage.skills.save(skillA)
        try await storage.skills.save(skillB)
        return Fixture(records: storage.records, skillA: skillA.id, skillB: skillB.id)
    }
}

private func record(_ skill: UUID?, age: TimeInterval, outcome: Outcome = .applied,
                    text: String? = "草稿", now: Date = fixedDate()) -> PolishRecord {
    let moment = now.addingTimeInterval(-age)
    return PolishRecord(skillID: skill, targetLabel: "Chrome", originalText: text,
                        resultText: text.map { $0 + "·结果" }, outcome: outcome,
                        createdAt: moment, updatedAt: moment)
}

// MARK: - Skills

@Test func aSkillRoundTripsThroughTheStore() async throws {
    let storage = try await PolishStorage.open(.memory)
    let skill = Skill(name: "增强", systemPrompt: "系统", userPromptTemplate: "改写：{input}",
                      sourceVersion: "dayi-default-1", isBuiltIn: true,
                      createdAt: fixedDate(), updatedAt: fixedDate())
    try await storage.skills.save(skill)
    #expect(try await storage.skills.skill(skill.id) == skill)
}

@Test func savingTheSameIdentityUpdatesInsteadOfDuplicating() async throws {
    let storage = try await PolishStorage.open(.memory)
    var skill = Skill(name: "增强", systemPrompt: "系统", userPromptTemplate: "{input}",
                      sourceVersion: "v", createdAt: fixedDate(), updatedAt: fixedDate())
    try await storage.skills.save(skill)
    skill.name = "增强 v2"
    skill.updatedAt = fixedDate(60)
    try await storage.skills.save(skill)
    let stored = try await storage.skills.skills(includingArchived: true)
    #expect(stored.count == 1)
    #expect(stored[0].name == "增强 v2")
    // The creation time belongs to the first save and an update must not move it.
    #expect(stored[0].createdAt == fixedDate())
    #expect(stored[0].updatedAt == fixedDate(60))
}

@Test func askingForASkillThatIsNotThereReturnsNil() async throws {
    let storage = try await PolishStorage.open(.memory)
    #expect(try await storage.skills.skill(UUID()) == nil)
    #expect(try await storage.skills.skills(includingArchived: true).isEmpty)
}

@Test func theBundledTemplateImportsAsTheBuiltInSkill() async throws {
    let storage = try await PolishStorage.open(.memory)
    let skill = Skill(builtIn: try PromptTemplate.bundled(), name: "Dayi 默认润色", now: fixedDate())
    try await storage.skills.save(skill)
    let stored = try #require(try await storage.skills.skill(skill.id))
    #expect(stored.isBuiltIn)
    #expect(stored.userPromptTemplate.contains("{input}"))
    #expect(stored.sourceVersion == "dayi-default-1")
}

// MARK: - Records

@Test func aRecordRoundTripsWithItsTextIntact() async throws {
    let storage = try await PolishStorage.open(.memory)
    let original = "e\u{0301}🙂\n第二行"
    let stored = PolishRecord(targetLabel: "Chrome", originalText: original, resultText: "é🙂",
                              outcome: .applied, createdAt: fixedDate(), updatedAt: fixedDate())
    try await storage.records.save(stored)
    let read = try #require(try await storage.records.record(stored.id))
    #expect(read == stored)
    #expect(read.originalText!.utf16.elementsEqual(original.utf16))
    #expect(!read.originalText!.utf16.elementsEqual(read.resultText!.utf16))
}

@Test func missingTextStaysDistinctFromEmptyText() async throws {
    let storage = try await PolishStorage.open(.memory)
    let absent = PolishRecord(targetLabel: "Chrome", originalText: nil, outcome: .running,
                              createdAt: fixedDate(), updatedAt: fixedDate())
    let empty = PolishRecord(targetLabel: "Chrome", originalText: "", outcome: .running,
                             createdAt: fixedDate(), updatedAt: fixedDate())
    try await storage.records.save(absent)
    try await storage.records.save(empty)
    #expect(try await storage.records.record(absent.id)?.originalText == nil)
    #expect(try await storage.records.record(empty.id)?.originalText == "")
}

@Test func updatingARecordKeepsTheTimeItWasCreated() async throws {
    let storage = try await PolishStorage.open(.memory)
    var stored = PolishRecord(targetLabel: "Chrome", originalText: "草稿", outcome: .running,
                              createdAt: fixedDate(), updatedAt: fixedDate())
    try await storage.records.save(stored)
    stored.outcome = .applied
    stored.resultText = "结果"
    stored.createdAt = fixedDate(9999)
    stored.updatedAt = fixedDate(60)
    try await storage.records.save(stored)
    let read = try #require(try await storage.records.record(stored.id))
    #expect(read.outcome == .applied)
    #expect(read.createdAt == fixedDate())
    #expect(read.updatedAt == fixedDate(60))
}

@Test(arguments: StoreKind.allCases) func recentReturnsTheNewestFirst(kind: StoreKind) async throws {
    let store = try await fixture(kind).records
    let older = record(nil, age: 120)
    let newer = record(nil, age: 60)
    let newest = record(nil, age: 0)
    for entry in [newer, newest, older] { try await store.save(entry) }
    #expect(try await store.recent(limit: 10).map(\.id) == [newest.id, newer.id, older.id])
    #expect(try await store.recent(limit: 2).map(\.id) == [newest.id, newer.id])
}

@Test(arguments: StoreKind.allCases) func recentWithNothingToReturnIsEmpty(kind: StoreKind) async throws {
    let store = try await fixture(kind).records
    #expect(try await store.recent(limit: 10).isEmpty)
    try await store.save(record(nil, age: 0))
    #expect(try await store.recent(limit: 0).isEmpty)
    #expect(try await store.recent(limit: -1).isEmpty)
}

@Test(arguments: StoreKind.allCases) func deletingARecordThatIsNotThereIsNotAnError(kind: StoreKind) async throws {
    let store = try await fixture(kind).records
    let kept = record(nil, age: 0)
    try await store.save(kept)
    try await store.delete(UUID())
    try await store.delete(kept.id)
    #expect(try await store.record(kept.id) == nil)
    #expect(try await store.recent(limit: 10).isEmpty)
}

// MARK: - Retention

@Test(arguments: StoreKind.allCases) func purgeAppliesAgeThenCountThenText(kind: StoreKind) async throws {
    let store = try await fixture(kind).records
    let now = fixedDate()
    let ancient = record(nil, age: 40 * 86_400)
    let old = record(nil, age: 10 * 86_400)
    let middle = record(nil, age: 3 * 86_400)
    let fresh = record(nil, age: 3_600)
    for entry in [ancient, old, middle, fresh] { try await store.save(entry) }
    let policy = RetentionPolicy(maxAge: 30 * 86_400, maxCount: 2, textMaxAge: 2 * 86_400)
    let report = try await store.purge(policy, now: now)
    #expect(report.deletedRows == 2)
    #expect(report.blankedTexts == 1)
    #expect(try await store.recent(limit: 10).map(\.id) == [fresh.id, middle.id])
    // The row survives its text: what happened stays countable after what was written is gone.
    let blanked = try #require(try await store.record(middle.id))
    #expect(blanked.originalText == nil)
    #expect(blanked.resultText == nil)
    #expect(blanked.outcome == .applied)
    #expect(try await store.record(fresh.id)?.originalText == "草稿")
}

@Test(arguments: StoreKind.allCases) func purgingAnEmptyStoreReportsNothing(kind: StoreKind) async throws {
    let store = try await fixture(kind).records
    let report = try await store.purge(.standard, now: fixedDate())
    #expect(report == PurgeReport(deletedRows: 0, blankedTexts: 0))
}

@Test(arguments: StoreKind.allCases) func anUnlimitedPolicyKeepsEverything(kind: StoreKind) async throws {
    let store = try await fixture(kind).records
    try await store.save(record(nil, age: 10 * 365 * 86_400))
    let report = try await store.purge(.unlimited, now: fixedDate())
    #expect(report == PurgeReport(deletedRows: 0, blankedTexts: 0))
    #expect(try await store.recent(limit: 10).count == 1)
}

@Test(arguments: StoreKind.allCases) func metadataOnlyBlanksEvenTheNewestText(kind: StoreKind) async throws {
    let store = try await fixture(kind).records
    let entry = record(nil, age: 1)
    try await store.save(entry)
    let report = try await store.purge(.metadataOnly, now: fixedDate())
    #expect(report.blankedTexts == 1)
    #expect(try await store.record(entry.id)?.originalText == nil)
}

@Test(arguments: StoreKind.allCases) func purgingTwiceDoesNotCountTheSameRowAgain(kind: StoreKind) async throws {
    let store = try await fixture(kind).records
    try await store.save(record(nil, age: 3 * 86_400))
    let policy = RetentionPolicy(textMaxAge: 86_400)
    #expect(try await store.purge(policy, now: fixedDate()).blankedTexts == 1)
    #expect(try await store.purge(policy, now: fixedDate()).blankedTexts == 0)
}

@Test(arguments: StoreKind.allCases) func aCountLimitOfZeroClearsTheHistory(kind: StoreKind) async throws {
    let store = try await fixture(kind).records
    try await store.save(record(nil, age: 0))
    #expect(try await store.purge(RetentionPolicy(maxCount: 0), now: fixedDate()).deletedRows == 1)
    #expect(try await store.recent(limit: 10).isEmpty)
}

// MARK: - Usage

@Test(arguments: StoreKind.allCases) func usageCountsAttemptsAndAppliedResultsApart(kind: StoreKind) async throws {
    let context = try await fixture(kind)
    let store = context.records
    for entry in [record(context.skillA, age: 60, outcome: .applied),
                  record(context.skillA, age: 120, outcome: .applied),
                  record(context.skillA, age: 180, outcome: .failed),
                  record(context.skillB, age: 90, outcome: .waiting),
                  record(nil, age: 30, outcome: .applied),
                  record(context.skillB, age: 40 * 86_400, outcome: .applied)] {
        try await store.save(entry)
    }
    let usage = try await store.usage(since: fixedDate().addingTimeInterval(-86_400))
    #expect(usage.map(\.skillID) == [context.skillA, context.skillB])
    #expect(usage[0].total == 3)
    #expect(usage[0].applied == 2)
    #expect(usage[0].lastUsedAt == fixedDate(-60))
    #expect(usage[1].total == 1)
    #expect(usage[1].applied == 0)
}

@Test(arguments: StoreKind.allCases) func usageOfAStoreWithNoSkillsIsEmpty(kind: StoreKind) async throws {
    let store = try await fixture(kind).records
    try await store.save(record(nil, age: 0))
    #expect(try await store.usage(since: fixedDate().addingTimeInterval(-86_400)).isEmpty)
}

// MARK: - Preferences

@Test func aPreferenceDistinguishesUnsetFromEmpty() async throws {
    let storage = try await PolishStorage.open(.memory)
    #expect(try await storage.preferences.value(forKey: "skill") == nil)
    try await storage.preferences.set("", forKey: "skill")
    #expect(try await storage.preferences.value(forKey: "skill") == "")
    try await storage.preferences.set("增强", forKey: "skill")
    #expect(try await storage.preferences.value(forKey: "skill") == "增强")
    try await storage.preferences.set(nil, forKey: "skill")
    #expect(try await storage.preferences.value(forKey: "skill") == nil)
}

// MARK: - Domain mapping

@Test func everyDomainStatePairMapsToOneStoredOutcome() async throws {
    let application: [ApplicationState] = [.pending, .blocked, .applying, .applied, .uncertain, .undone]
    let expected: [Outcome] = [.waiting, .waiting, .applying, .applied, .uncertain, .undone]
    for (state, outcome) in zip(application, expected) {
        #expect(Outcome(compute: .succeeded, application: state) == outcome)
        // A request that never produced text is a failure whatever its application state says.
        #expect(Outcome(compute: .failed, application: state) == .failed)
        #expect(Outcome(compute: .running, application: state) == .running)
    }
    #expect(Outcome.applied.isFinal)
    #expect(!Outcome.running.isFinal)
    #expect(!Outcome.applying.isFinal)
}

@MainActor
@Test func afinishedJobSnapshotsIntoAStorableRecord() async throws {
    let jobs = PolishJobs { _ in "润色结果" }
    let target = FakeTarget(document: "前 草稿 后", range: NSRange(location: 2, length: 2))
    let id = try jobs.start(target: target)
    await jobs.wait(for: id)
    let job = try #require(jobs.jobs.first)
    #expect(job.applicationState == .applied)

    let storage = try await PolishStorage.open(.memory)
    let skill = Skill(name: "增强", systemPrompt: "s", userPromptTemplate: "{input}", sourceVersion: "v")
    try await storage.skills.save(skill)
    let snapshot = PolishRecord(job: job, skillID: skill.id, updatedAt: fixedDate())
    try await storage.records.save(snapshot)

    let stored = try #require(try await storage.records.record(job.id))
    #expect(stored.id == job.id)
    #expect(stored.outcome == .applied)
    #expect(stored.originalText == "草稿")
    #expect(stored.resultText == "润色结果")
    #expect(stored.targetLabel == "TestPad")
    #expect(stored.skillID == skill.id)
    // Timestamps come from the job and land on the millisecond the column can hold.
    #expect(abs(stored.createdAt.timeIntervalSince(job.createdAt)) < 0.001)
}

/// The smallest target that satisfies the domain contract, so a real job can run in a test.
@MainActor
private final class FakeTarget: TextTarget {
    let id = "fake:1"
    let label = "TestPad"
    let supportsBackgroundWrite = true
    let isFocused = true
    private var document: String
    private let range: NSRange

    init(document: String, range: NSRange) {
        self.document = document
        self.range = range
    }

    func capture() throws -> TextSnapshot { try TextSnapshot(document: document, range: range) }
    func readDocument() throws -> String { document }

    func replace(range: NSRange, with text: String, expectedDocument: String) async throws {
        guard document.utf16.elementsEqual(expectedDocument.utf16) else { throw TargetError.conflict }
        document = (document as NSString).replacingCharacters(in: range, with: text)
    }

    func returnToContext(range: NSRange) throws {}
}

@Test func recordKeepsTheModelName() async throws {
    let storage = try await PolishStorage.open(.memory)
    let record = PolishRecord(targetLabel: "Chrome", model: "deepseek-v4-pro", outcome: .applied)
    try await storage.records.save(record)
    #expect(try await storage.records.record(record.id)?.model == "deepseek-v4-pro")
    let unnamed = PolishRecord(targetLabel: "Chrome", outcome: .failed)
    try await storage.records.save(unnamed)
    #expect(try await storage.records.record(unnamed.id)?.model == nil)
}
