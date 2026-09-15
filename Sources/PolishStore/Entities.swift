import Foundation
import PolishCore

/// A stored prompt skill. Today one built-in skill is compiled into the bundle; the stored
/// form is what makes a skill editable, replaceable and countable.
public struct Skill: Sendable, Equatable, Identifiable {
    public let id: UUID
    public var name: String
    public var systemPrompt: String
    /// Must contain `{input}`; `PromptTemplate.render` has nowhere to put the draft without it.
    public var userPromptTemplate: String
    public var sourceVersion: String
    /// A shipped skill. The app may replace its body on upgrade; a user skill it must not touch.
    public var isBuiltIn: Bool
    public var createdAt: Date
    public var updatedAt: Date
    /// Archived skills keep their records readable but leave the picker and the name index.
    public var archivedAt: Date?

    public init(id: UUID = UUID(), name: String, systemPrompt: String, userPromptTemplate: String,
                sourceVersion: String, isBuiltIn: Bool = false,
                createdAt: Date = Date(), updatedAt: Date = Date(), archivedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.systemPrompt = systemPrompt
        self.userPromptTemplate = userPromptTemplate
        self.sourceVersion = sourceVersion
        self.isBuiltIn = isBuiltIn
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.archivedAt = archivedAt
    }
}

/// How one polish attempt ended. These strings are the on-disk contract: they are written
/// out and matched by a CHECK constraint, so they are mapped from the domain explicitly
/// rather than derived from a case name that refactoring is free to change.
public enum Outcome: String, Sendable, CaseIterable {
    case running, failed, waiting, applying, applied, uncertain, undone

    /// An attempt that can still change. A row left this way by a crash is resumable state,
    /// not a result, and reporting counts it separately.
    public var isFinal: Bool { self != .running && self != .applying }
}

/// One polish attempt. The text columns are optional because retention may strip them while
/// keeping the row: what happened stays countable after what was written is gone.
public struct PolishRecord: Sendable, Equatable, Identifiable {
    public let id: UUID
    public var skillID: UUID?
    public var targetLabel: String
    public var website: WebsiteSource?
    /// The model the provider named for this attempt; nil for rows written before it was kept.
    public var model: String?
    public var originalText: String?
    public var resultText: String?
    public var outcome: Outcome
    public var message: String?
    public var failure: RecordedFailure?
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), skillID: UUID? = nil, targetLabel: String, model: String? = nil,
                website: WebsiteSource? = nil,
                originalText: String? = nil, resultText: String? = nil,
                outcome: Outcome, message: String? = nil, failure: RecordedFailure? = nil,
                createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.skillID = skillID
        self.targetLabel = targetLabel
        self.website = website
        self.model = model
        self.originalText = originalText
        self.resultText = resultText
        self.outcome = outcome
        self.message = message
        self.failure = failure
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// What the store is allowed to keep. Text a user drafted is the sensitive part of this
/// database, so its lifetime is a policy the caller sets, not a side effect of the schema.
public struct RetentionPolicy: Sendable, Equatable {
    /// Rows older than this are deleted outright.
    public var maxAge: TimeInterval?
    /// Only the newest rows survive, counted after `maxAge` has been applied.
    public var maxCount: Int?
    /// Text older than this is blanked while the row and its outcome stay. Nil keeps text
    /// for as long as the row lives.
    public var textMaxAge: TimeInterval?

    public init(maxAge: TimeInterval? = nil, maxCount: Int? = nil, textMaxAge: TimeInterval? = nil) {
        self.maxAge = maxAge
        self.maxCount = maxCount
        self.textMaxAge = textMaxAge
    }

    /// Enough history to answer "what did I run last week" without keeping drafts indefinitely.
    public static let standard = RetentionPolicy(maxAge: 30 * 86_400, maxCount: 500, textMaxAge: 7 * 86_400)
    /// Counts only: every draft and result is blanked as soon as a purge runs.
    public static let metadataOnly = RetentionPolicy(maxAge: 30 * 86_400, maxCount: 500, textMaxAge: 0)
    public static let unlimited = RetentionPolicy()
}

public struct PurgeReport: Sendable, Equatable {
    public let deletedRows: Int
    public let blankedTexts: Int
    public init(deletedRows: Int, blankedTexts: Int) {
        self.deletedRows = deletedRows
        self.blankedTexts = blankedTexts
    }
}

/// How often one skill was used and how often its result actually landed. This is the input
/// a recommendation needs, and it is derived from the records rather than counted into the
/// skill row, so a deleted record corrects the count instead of leaving it overstated.
public struct SkillUsage: Sendable, Equatable, Identifiable {
    public let skillID: UUID
    public let total: Int
    public let applied: Int
    public let lastUsedAt: Date
    public var id: UUID { skillID }

    public init(skillID: UUID, total: Int, applied: Int, lastUsedAt: Date) {
        self.skillID = skillID
        self.total = total
        self.applied = applied
        self.lastUsedAt = lastUsedAt
    }
}
