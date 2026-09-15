import Foundation
import PolishCore

/// The only file in this module that knows the domain types. Storage depends on the domain;
/// the domain never depends on storage, so PolishCore keeps working with no database at all.
extension Outcome {
    /// The domain carries two independent states: whether the request finished, and what
    /// happened to the text. One row records one outcome, so the pair is collapsed here,
    /// deliberately and in one place. A failed request wins over its application state,
    /// which is only `blocked` because nothing was produced to apply.
    public init(compute: ComputeState, application: ApplicationState) {
        switch compute {
        case .running: self = .running
        case .failed: self = .failed
        case .succeeded:
            switch application {
            case .pending, .blocked: self = .waiting
            case .applying: self = .applying
            case .applied: self = .applied
            case .uncertain: self = .uncertain
            case .undone: self = .undone
            }
        }
    }
}

extension PolishRecord {
    /// Snapshots a live job. The target itself is not stored: an accessibility element
    /// belongs to a process, so a stored handle would be a promise this layer cannot keep.
    /// The label is kept because it is what a person recognises in a list.
    public init(job: PolishJob, skillID: UUID?, updatedAt: Date = Date()) {
        self.init(id: job.id, skillID: skillID, targetLabel: job.targetLabel,
                  model: job.model.isEmpty ? nil : job.model,
                  website: job.website,
                  originalText: job.originalText, resultText: job.result,
                  outcome: Outcome(compute: job.computeState, application: job.applicationState),
                  message: job.message, failure: job.failure, createdAt: job.createdAt, updatedAt: updatedAt)
    }
}

extension Skill {
    /// Imports the bundled template as the built-in skill, so the first launch of a stored
    /// world starts from exactly what the app runs today.
    public init(builtIn template: PromptTemplate, name: String, id: UUID = UUID(), now: Date = Date()) {
        self.init(id: id, name: name, systemPrompt: template.systemPrompt,
                  userPromptTemplate: template.userPromptTemplate,
                  sourceVersion: template.sourceVersion, isBuiltIn: true,
                  createdAt: now, updatedAt: now)
    }
}
