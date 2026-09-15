import Foundation
import PolishCore
import PolishStore
import Testing
@testable import TextPolishApp

@MainActor
struct PromptSettingsTests {
    @Test func localEditPersistsWithoutChangingDefaultOrCapturedSelection() async throws {
        let db = try await PolishStorage.open(.memory)
        let settings = PromptSettings()
        let defaultID = UUID()
        await settings.attach(db.skills, defaultSkillID: defaultID)
        let before = try settings.selection()
        try await settings.save(system: "Keep every identifier.", user: "Draft:\n{input}")
        let custom = try settings.selection()
        #expect(settings.isCustom)
        #expect(custom.template.systemPrompt == "Keep every identifier.")
        #expect(before.template.systemPrompt == (try PromptTemplate.bundled()).systemPrompt)
        #expect(before.skillID == defaultID)
        #expect(custom.skillID != before.skillID)

        let reopened = PromptSettings()
        await reopened.attach(db.skills, defaultSkillID: defaultID)
        #expect(try reopened.selection().skillID == custom.skillID)
        #expect(try reopened.selection().template.systemPrompt == custom.template.systemPrompt)
        // A new shipped default must not replace an explicit local override.
        let nextDefault = try PromptTemplate(systemPrompt: "New default", userPromptTemplate: "New: {input}", sourceVersion: "next")
        let upgraded = PromptSettings(defaultTemplate: .success(nextDefault))
        await upgraded.attach(db.skills, defaultSkillID: UUID())
        #expect(try upgraded.selection().skillID == custom.skillID)

        let record = PolishRecord(skillID: custom.skillID, targetLabel: "Synthetic", originalText: "Draft", resultText: "Edited", outcome: .applied)
        try await db.records.save(record)
        try await settings.save(system: "Another local version", user: "{input}")
        let customID = try #require(custom.skillID)
        let oldSkill = try #require(try await db.skills.skill(customID))
        #expect(oldSkill.archivedAt != nil)
        #expect(oldSkill.systemPrompt == custom.template.systemPrompt)
        #expect(try await db.records.record(record.id)?.skillID == custom.skillID)

        let baseline = try settings.bundled()
        try await settings.save(system: baseline.systemPrompt, user: baseline.userPromptTemplate)
        #expect(!settings.isCustom)
        #expect(try await db.skills.customPrompt() == nil)
        #expect(try settings.selection().skillID == defaultID)
        let reset = PromptSettings()
        await reset.attach(db.skills, defaultSkillID: defaultID)
        #expect(!reset.isCustom)
    }

    @Test func failedSaveRollsBackRevisionAndLeavesCurrentSelection() async throws {
        let db = try await PolishStorage.open(.memory)
        let settings = PromptSettings()
        await settings.attach(db.skills, defaultSkillID: nil)
        try await settings.save(system: "Original local", user: "{input}")
        let selected = try settings.selection()
        try await db.database.write { session in
            try session.execute("CREATE TRIGGER reject_prompt BEFORE UPDATE ON preferences WHEN NEW.key = 'prompt.custom-skill' BEGIN SELECT RAISE(ABORT, 'synthetic failure'); END")
        }
        await #expect(throws: (any Error).self) { try await settings.save(system: "Unsaved local", user: "Draft: {input}") }
        #expect(try settings.selection().skillID == selected.skillID)
        #expect(try await db.skills.customPrompt()?.id == selected.skillID)
        #expect(try await db.skills.skills(includingArchived: true).count == 1)
    }

    @Test(arguments: ["missing", "{input} and {input}"])
    func invalidPlaceholdersNeverChangeSavedPrompt(user: String) async throws {
        let db = try await PolishStorage.open(.memory)
        let settings = PromptSettings()
        await settings.attach(db.skills, defaultSkillID: nil)
        await #expect(throws: PolishError.self) { try await settings.save(system: "Keep intent", user: user) }
        #expect(try await db.skills.customPrompt() == nil)
        #expect(!settings.isCustom)
    }
}
