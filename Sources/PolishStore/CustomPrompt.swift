import Foundation
import PolishCore

extension SQLiteSkillStore {
    /// A local override points to an immutable skill revision. Clearing the preference
    /// follows the bundled default again; old revisions remain available to history.
    public func customPrompt() async throws -> Skill? {
        try await database.read { session in
            guard let id = try session.query("SELECT value FROM preferences WHERE key = 'prompt.custom-skill'", row: { try $0.uuid("value") }).first else { return nil }
            guard let skill = try session.query("SELECT * FROM skills WHERE id = ? AND is_built_in = 0 AND archived_at IS NULL", [SQLValue(id)], row: Skill.init(row:)).first else {
                throw PersistenceError.decoding("prompt.custom-skill")
            }
            return skill
        }
    }

    public func saveCustomPrompt(_ template: PromptTemplate?, name: String) async throws -> Skill? {
        try template?.validate()
        let now = Date()
        let skill = template.map { Skill(name: name, systemPrompt: $0.systemPrompt,
                                         userPromptTemplate: $0.userPromptTemplate, sourceVersion: $0.sourceVersion,
                                         createdAt: now, updatedAt: now) }
        try await database.write { session in
            _ = try session.run("""
                UPDATE skills SET archived_at = ?, updated_at = ?
                WHERE id = (SELECT value FROM preferences WHERE key = 'prompt.custom-skill') AND is_built_in = 0
                """, [SQLValue(now), SQLValue(now)])
            if let skill {
                _ = try session.run("""
                    INSERT INTO skills (id, name, system_prompt, user_prompt_template, source_version,
                                        is_built_in, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, 0, ?, ?)
                    """, [SQLValue(skill.id), .text(skill.name), .text(skill.systemPrompt),
                          .text(skill.userPromptTemplate), .text(skill.sourceVersion), SQLValue(now), SQLValue(now)])
                _ = try session.run("INSERT INTO preferences (key, value, updated_at) VALUES ('prompt.custom-skill', ?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at", [SQLValue(skill.id), SQLValue(now)])
            } else {
                _ = try session.run("DELETE FROM preferences WHERE key = 'prompt.custom-skill'")
            }
        }
        return skill
    }
}
