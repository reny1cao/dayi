import Foundation
import Observation
import PolishCore
import PolishStore

/// The window's view of stored history, and the write path that keeps it current.
///
/// Persistence is secondary to polishing: every failure here is reported and swallowed, so a
/// database that cannot be opened or written degrades the app to what it was before — a
/// session that forgets — and never stops a press from working.
@MainActor @Observable
final class PolishHistory {
    private(set) var records: [PolishRecord] = []
    private(set) var failure: String?
    /// True once the file is open and its rows are loaded. Until then the list is whatever
    /// this run produced.
    private(set) var isReady = false

    @ObservationIgnored private var store: (any RecordStore)?
    /// Written before the database finished opening. A job that starts and finishes during
    /// launch would otherwise be the one record that is silently lost.
    @ObservationIgnored private var pending: [PolishRecord] = []
    @ObservationIgnored private var writer: Task<Void, Never>?
    @ObservationIgnored private let limit: Int

    init(limit: Int = 200) { self.limit = limit }

    func attach(_ store: any RecordStore, purging policy: RetentionPolicy) async {
        self.store = store
        do {
            for record in pending { try await store.save(record) }
            pending = []
            try await store.purge(policy, now: Date())
            records = try await recovering(try await store.recent(limit: limit), in: store)
            isReady = true
        } catch {
            report(error)
        }
    }

    /// Records the current state of one job. Writes are chained, so two updates to the same
    /// job cannot land out of order and leave the file describing an older state than the
    /// screen does.
    func save(_ record: PolishRecord) {
        upsert(record)
        guard let store else {
            pending.append(record)
            return
        }
        enqueue { try await store.save(record) }
    }

    /// Capture and configuration failures happen before a PolishJob exists. They still
    /// represent a user's attempt, but have no confirmed text or model response to store.
    func recordFailure(in target: String, message: String, startedAt: Date, failure: RecordedFailure? = nil,
                       website: WebsiteSource? = nil) {
        save(PolishRecord(targetLabel: target, website: website, outcome: .failed, message: message, failure: failure,
                          createdAt: startedAt, updatedAt: Date()))
    }

    func remove(_ id: UUID) {
        records.removeAll { $0.id == id }
        pending.removeAll { $0.id == id }
        guard let store else { return }
        enqueue { try await store.delete(id) }
    }

    /// Clearing is the retention policy taken to its limit, so it goes through the same path
    /// rather than a second deletion route with its own behaviour.
    func clear() {
        records = []
        pending = []
        guard let store else { return }
        enqueue { _ = try await store.purge(RetentionPolicy(maxCount: 0), now: Date()) }
    }

    func report(_ error: Error) {
        failure = (error as? LocalizedError)?.errorDescription ?? L10n.tr("历史记录未能保存。")
    }

    /// Waits for every queued write. Tests need it; nothing in the app does, because a
    /// dropped write is reported rather than waited on.
    func settle() async { await writer?.value }

    private func enqueue(_ work: @escaping @Sendable () async throws -> Void) {
        let previous = writer
        writer = Task { [weak self] in
            await previous?.value
            do { try await work() } catch { self?.report(error) }
        }
    }

    private func upsert(_ record: PolishRecord) {
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            records[index] = record
        } else {
            records.insert(record, at: 0)
        }
    }

    /// A row left mid-flight by a quit or a crash is not a result. A request that never
    /// produced text ends as failed. A write that was in progress ends as uncertain: nothing
    /// left in this process can prove whether it landed, and the project does not guess.
    private func recovering(_ loaded: [PolishRecord], in store: any RecordStore) async throws -> [PolishRecord] {
        var restored: [PolishRecord] = []
        for var record in loaded {
            guard !record.outcome.isFinal else {
                restored.append(record)
                continue
            }
            let wasWriting = record.outcome == .applying
            record.outcome = wasWriting ? .uncertain : .failed
            record.message = wasWriting ? L10n.tr("应用退出时正在写回，无法确认结果。") : L10n.tr("应用退出时任务未完成。")
            record.failure = .interrupted(wasWriting: wasWriting)
            record.updatedAt = Date()
            try await store.save(record)
            restored.append(record)
        }
        return restored
    }
}

/// Opens the database and brings the built-in skill up to date. Separate from `PolishHistory`
/// so the history has one job — the record list — and the open sequence has another.
enum PolishStorageBootstrap {
    struct Opened: Sendable {
        let records: any RecordStore
        let preferences: any PreferenceStore
        let skills: SQLiteSkillStore
        let skillID: UUID?
        let location: URL?
    }

    static func open(_ location: Database.Location) async throws -> Opened {
        let storage = try await PolishStorage.open(location)
        let url: URL? = if case .file(let url) = location { url } else { nil }
        return Opened(records: storage.records, preferences: storage.preferences, skills: storage.skills,
                      skillID: try await builtInSkill(in: storage.skills), location: url)
    }

    /// The bundled template is the one skill the app ships. A new template version becomes a
    /// new skill and the old one is archived, so records keep pointing at the text that
    /// actually produced them.
    private static func builtInSkill(in store: some SkillStore) async throws -> UUID? {
        let template = try PromptTemplate.bundled()
        let stored = try await store.skills(includingArchived: false)
        if let current = stored.first(where: \.isBuiltIn) {
            guard current.sourceVersion != template.sourceVersion
                    || !current.userPromptTemplate.utf16.elementsEqual(template.userPromptTemplate.utf16) else {
                return current.id
            }
            try await store.archive(current.id, at: Date())
        }
        let skill = Skill(builtIn: template, name: L10n.tr("Dayi 默认润色"))
        try await store.save(skill)
        return skill.id
    }
}
