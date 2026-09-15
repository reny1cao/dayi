import Foundation
import Observation

public enum ComputeState: Sendable { case running, succeeded, failed }
public enum ApplicationState: Sendable { case pending, blocked, applying, applied, uncertain, undone }

public struct PolishJob: Identifiable, Sendable {
    public let id: UUID
    public let targetLabel: String
    public let website: WebsiteSource?
    public let originalText: String
    public let createdAt: Date
    /// The model this job was sent to; replaced by the provider's own name once it answers.
    public fileprivate(set) var model: String
    public fileprivate(set) var computeState: ComputeState = .running
    public fileprivate(set) var applicationState: ApplicationState = .pending
    public fileprivate(set) var result: String?
    public fileprivate(set) var message: String?
    public fileprivate(set) var failure: RecordedFailure?
}

/// Owned by the resident host, not a transient window or popover.
@MainActor @Observable
public final class PolishJobs {
    public typealias Generate = @Sendable (String) async throws -> Completion
    public private(set) var jobs: [PolishJob] = []
    @ObservationIgnored private var contexts: [UUID: Context] = [:]
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private let generate: Generate

    private struct Context {
        let target: any TextTarget
        let snapshot: TextSnapshot
        var edit: AppliedEdit?
    }

    private init(completing generate: @escaping Generate) { self.generate = generate }

    /// Text in, text out, with no model name attached, for test generators.
    public convenience init(generate: @escaping @Sendable (String) async throws -> String) {
        self.init(completing: { Completion(text: try await generate($0), model: "") })
    }

    /// A generator that also names the model that answered. A factory rather than a second
    /// initializer, so a trailing closure still has exactly one initializer to match.
    public static func completing(_ generate: @escaping Generate) -> PolishJobs { PolishJobs(completing: generate) }

    @discardableResult
    public func start(target: any TextTarget, model: String = "", website: WebsiteSource? = nil,
                      completing: Generate? = nil) throws -> UUID {
        guard !tasks.keys.contains(where: { contexts[$0]?.target.id == target.id }) else { throw TargetError.busy }
        let snapshot = try target.capture()
        guard !snapshot.selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw PolishError.emptyInput }
        let id = UUID()
        contexts[id] = Context(target: target, snapshot: snapshot)
        jobs.append(PolishJob(id: id, targetLabel: target.label, website: website, originalText: snapshot.selectedText, createdAt: Date(),
                              model: model))
        let generate = completing ?? self.generate
        tasks[id] = Task { [weak self] in
            defer { self?.tasks[id] = nil }
            do {
                let completion = try await generate(snapshot.selectedText)
                await self?.finish(id, result: .success(completion))
            } catch {
                await self?.finish(id, result: .failure(error))
            }
        }
        return id
    }

    public func wait(for id: UUID) async { await tasks[id]?.value }

    /// A second press in the original input applies the result that is still waiting there.
    /// A result whose snapshot no longer matches the input has expired: the user kept typing, or
    /// sent the draft. It is marked as a conflict and stops claiming the key, so the press that
    /// found it polishes the current text instead of retrying a write that can never succeed.
    @discardableResult
    public func applyWaitingResult(to targetID: String) -> Bool {
        guard let index = jobs.lastIndex(where: {
            contexts[$0.id]?.target.id == targetID && $0.computeState == .succeeded
                && [.pending, .blocked].contains($0.applicationState) && $0.failure != .target(.conflict)
        }), let context = contexts[jobs[index].id] else { return false }
        if let current = try? context.target.readDocument(), !current.utf16.elementsEqual(context.snapshot.document.utf16) {
            jobs[index].message = TargetError.conflict.localizedDescription
            jobs[index].failure = .target(.conflict)
            return false
        }
        apply(jobs[index].id)
        return true
    }

    private func finish(_ id: UUID, result: Result<Completion, Error>) async {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        switch result {
        case .success(let completion) where !completion.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
            jobs[index].computeState = .succeeded
            jobs[index].result = completion.text
            if !completion.model.isEmpty { jobs[index].model = completion.model }
            await applyResult(id)
        case .success:
            jobs[index].computeState = .failed
            jobs[index].applicationState = .blocked
            jobs[index].message = PolishError.emptyResult.localizedDescription
            jobs[index].failure = .polish(.emptyResult)
        case .failure(let error):
            jobs[index].computeState = .failed
            jobs[index].applicationState = .blocked
            jobs[index].message = (error as? PolishError)?.localizedDescription ?? L10n.tr("润色请求未完成。")
            jobs[index].failure = RecordedFailure(error) ?? .requestIncomplete
        }
    }

    public func apply(_ id: UUID) {
        guard tasks[id] == nil else { return }
        tasks[id] = Task { [weak self] in
            defer { self?.tasks[id] = nil }
            await self?.applyResult(id)
        }
    }

    private func applyResult(_ id: UUID) async {
        guard let index = jobs.firstIndex(where: { $0.id == id }), let context = contexts[id],
              jobs[index].computeState == .succeeded, let result = jobs[index].result,
              [.pending, .blocked].contains(jobs[index].applicationState) else { return }
        do {
            guard context.target.supportsBackgroundWrite || context.target.isFocused else { throw TargetError.foregroundRequired }
            guard try context.target.readDocument().utf16.elementsEqual(context.snapshot.document.utf16) else { throw TargetError.conflict }
            jobs[index].applicationState = .applying
            try await context.target.replace(range: context.snapshot.range, with: result, expectedDocument: context.snapshot.document)
            guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
            guard try context.target.readDocument().utf16.elementsEqual(context.snapshot.replacing(with: result).utf16) else { throw TargetError.uncertain }
            contexts[id]?.edit = AppliedEdit(original: context.snapshot, replacement: result)
            jobs[index].applicationState = .applied
            jobs[index].message = nil
            jobs[index].failure = nil
        } catch {
            guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
            // A post-write read failure is uncertain even if the underlying error says unavailable.
            let uncertain = jobs[index].applicationState == .applying && ![.notApplied, .conflict, .foregroundRequired].contains(error as? TargetError)
            jobs[index].applicationState = uncertain ? .uncertain : .blocked
            jobs[index].message = uncertain ? TargetError.uncertain.localizedDescription : ((error as? TargetError)?.localizedDescription ?? L10n.tr("无法应用结果。"))
            jobs[index].failure = uncertain ? .target(.uncertain) : RecordedFailure(error) ?? .applicationFailed
        }
    }

    public func undo(_ id: UUID) {
        guard tasks[id] == nil else { return }
        tasks[id] = Task { [weak self] in
            defer { self?.tasks[id] = nil }
            await self?.undoResult(id)
        }
    }

    private func undoResult(_ id: UUID) async {
        guard let index = jobs.firstIndex(where: { $0.id == id }), jobs[index].applicationState == .applied,
              let context = contexts[id], let edit = context.edit else { return }
        var writing = false
        do {
            guard context.target.supportsBackgroundWrite || context.target.isFocused else { throw TargetError.foregroundRequired }
            let current = try context.target.readDocument()
            let restored = try edit.undoDocument(from: current)
            writing = true
            try await context.target.replace(range: edit.range, with: edit.original.selectedText, expectedDocument: current)
            guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
            guard try context.target.readDocument().utf16.elementsEqual(restored.utf16) else { throw TargetError.uncertain }
            jobs[index].applicationState = .undone
            jobs[index].message = nil
            jobs[index].failure = nil
        } catch {
            guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
            if writing, ![.notApplied, .conflict, .foregroundRequired].contains(error as? TargetError) {
                jobs[index].applicationState = .uncertain
                jobs[index].message = TargetError.uncertain.localizedDescription
                jobs[index].failure = .target(.uncertain)
            } else {
                jobs[index].message = (error as? TargetError)?.localizedDescription ?? TargetError.cannotUndo.localizedDescription
                jobs[index].failure = RecordedFailure(error) ?? .target(.cannotUndo)
            }
        }
    }

    public func returnToContext(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }), let context = contexts[id] else { return }
        guard tasks[id] == nil || jobs[index].computeState == .running else { return }
        do {
            let current = try context.target.readDocument()
            let range: NSRange
            if jobs[index].applicationState == .applied, let edit = context.edit {
                do { range = try edit.validatedRange(in: current) }
                catch { throw TargetError.conflict }
            } else {
                guard current.utf16.elementsEqual(context.snapshot.document.utf16) else { throw TargetError.conflict }
                range = context.snapshot.range
            }
            try context.target.returnToContext(range: range)
            jobs[index].message = nil
            jobs[index].failure = nil
        } catch {
            jobs[index].message = (error as? TargetError)?.localizedDescription ?? TargetError.unavailable.localizedDescription
            jobs[index].failure = RecordedFailure(error) ?? .target(.unavailable)
        }
    }

    /// Explicit user dismissal also removes the text and target handles from memory.
    public func dismiss(_ id: UUID) {
        guard tasks[id] == nil else { return }
        jobs.removeAll { $0.id == id }
        contexts[id] = nil
    }
}
