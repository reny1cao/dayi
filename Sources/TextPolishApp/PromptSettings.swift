import Foundation
import Observation
import PolishCore
import PolishStore

@MainActor @Observable
final class PromptSettings {
    struct Selection: Sendable {
        let template: PromptTemplate
        let skillID: UUID?
    }

    @ObservationIgnored private let defaultTemplate: Result<PromptTemplate, Error>
    @ObservationIgnored private var store: SQLiteSkillStore?
    @ObservationIgnored private var defaultSkillID: UUID?
    private(set) var current: Selection?
    private(set) var isCustom = false
    private(set) var isReady = false
    private(set) var isSaving = false
    private(set) var failure: String?

    init(defaultTemplate: Result<PromptTemplate, Error> = Result { try .bundled() }) {
        self.defaultTemplate = defaultTemplate
        do { current = Selection(template: try defaultTemplate.get(), skillID: nil) }
        catch { failure = error.localizedDescription }
    }

    func bundled() throws -> PromptTemplate { try defaultTemplate.get() }

    func selection() throws -> Selection {
        if let current { return current }
        return Selection(template: try defaultTemplate.get(), skillID: nil)
    }

    func attach(_ store: SQLiteSkillStore, defaultSkillID: UUID?) async {
        self.store = store
        self.defaultSkillID = defaultSkillID
        isReady = true
        do {
            if let saved = try await store.customPrompt() {
                let template = try PromptTemplate(systemPrompt: saved.systemPrompt, userPromptTemplate: saved.userPromptTemplate,
                                                  sourceVersion: saved.sourceVersion)
                current = Selection(template: template, skillID: saved.id)
                isCustom = true
            } else {
                current = Selection(template: try bundled(), skillID: defaultSkillID)
            }
            failure = nil
        } catch {
            failure = L10n.tr("无法读取自定义提示词，当前使用默认内容：") + error.localizedDescription
        }
    }

    func save(system: String, user: String) async throws {
        guard !isSaving, let store, isReady else { throw PolishError.invalidConfiguration("历史数据库尚未打开，稍后再保存") }
        let baseline = try bundled()
        let usesDefault = system.utf16.elementsEqual(baseline.systemPrompt.utf16)
            && user.utf16.elementsEqual(baseline.userPromptTemplate.utf16)
        let template = try PromptTemplate(systemPrompt: system, userPromptTemplate: user,
                                          sourceVersion: usesDefault ? baseline.sourceVersion : "custom-" + UUID().uuidString)
        isSaving = true
        defer { isSaving = false }
        let saved = try await store.saveCustomPrompt(usesDefault ? nil : template, name: L10n.tr("Dayi 自定义润色"))
        current = Selection(template: usesDefault ? baseline : template, skillID: saved?.id ?? defaultSkillID)
        isCustom = !usesDefault
        failure = nil
    }
}
