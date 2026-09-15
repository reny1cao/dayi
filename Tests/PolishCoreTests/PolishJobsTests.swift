import Foundation
import Testing
@testable import PolishCore

private actor GenerationGate {
    var requests: [String: CheckedContinuation<String, Error>] = [:]
    var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func generate(_ input: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            requests[input] = continuation
            let ready = waiters.filter { requests.count >= $0.0 }
            waiters.removeAll { requests.count >= $0.0 }
            for (_, waiter) in ready { waiter.resume() }
        }
    }

    func waitForRequests(_ count: Int) async {
        if requests.count >= count { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }

    func resolve(_ input: String, result: Result<String, Error>) {
        requests.removeValue(forKey: input)!.resume(with: result)
    }
}

@MainActor
private final class MemoryTarget: TextTarget {
    let id = UUID().uuidString
    let label = "合成输入区"
    var supportsBackgroundWrite = true
    var isFocused = true
    var document: String
    var range: NSRange
    var valid = true
    var ignoreWrites = false
    var failReadsAfterWrite = false
    var writes = 0
    var replaceCalls = 0
    var focusCalls = 0
    var beforeWrite: (() async throws -> Void)?
    var afterWrite: (() -> Void)?

    init(_ document: String, selected: String) {
        self.document = document
        range = (document as NSString).range(of: selected)
    }

    func capture() throws -> TextSnapshot { try TextSnapshot(document: readDocument(), range: range) }
    func readDocument() throws -> String {
        guard valid, !(failReadsAfterWrite && writes > 0) else { throw TargetError.unavailable }
        return document
    }
    func replace(range: NSRange, with text: String, expectedDocument: String) async throws {
        replaceCalls += 1
        try await beforeWrite?()
        guard try readDocument().utf16.elementsEqual(expectedDocument.utf16) else { throw TargetError.conflict }
        writes += 1
        if !ignoreWrites { document = (document as NSString).replacingCharacters(in: range, with: text) }
        afterWrite?()
    }
    func returnToContext(range: NSRange) throws {
        guard valid else { throw TargetError.unavailable }
        focusCalls += 1
        isFocused = true
        self.range = range
    }
}

@MainActor @Test func websiteSourceStaysWithItsJobWhenAnotherWebsiteStarts() async throws {
    let gate = GenerationGate()
    let jobs = PolishJobs { try await gate.generate($0) }
    let firstTarget = MemoryTarget("first", selected: "first")
    firstTarget.supportsBackgroundWrite = false
    let first = try jobs.start(target: firstTarget, website: WebsiteSource(host: "mail.google.com"))
    let second = try jobs.start(target: MemoryTarget("second", selected: "second"), website: WebsiteSource(host: "chatgpt.com"))
    await gate.waitForRequests(2)
    firstTarget.isFocused = false
    await gate.resolve("second", result: .failure(PolishError.emptyResult))
    await gate.resolve("first", result: .success("result"))
    await jobs.wait(for: first)
    await jobs.wait(for: second)
    #expect(jobs.jobs.first(where: { $0.id == first })?.website?.host == "mail.google.com")
    #expect(jobs.jobs.first(where: { $0.id == first })?.applicationState == .blocked)
    #expect(firstTarget.writes == 0)
    #expect(jobs.jobs.first(where: { $0.id == second })?.website?.host == "chatgpt.com")
    #expect(jobs.jobs.first(where: { $0.id == second })?.computeState == .failed)
}

@MainActor @Test func suspendedWriteKeepsTargetBusyAndSurvivesOtherJobDismissal() async throws {
    let gate = GenerationGate()
    let jobs = PolishJobs { _ in "result" }
    let firstTarget = MemoryTarget("first", selected: "first")
    let first = try jobs.start(target: firstTarget)
    await jobs.wait(for: first)
    let secondTarget = MemoryTarget("second", selected: "second")
    secondTarget.beforeWrite = { _ = try await gate.generate("write") }
    let second = try jobs.start(target: secondTarget)
    await gate.waitForRequests(1)
    #expect(throws: TargetError.busy) { try jobs.start(target: secondTarget) }
    jobs.dismiss(second)
    jobs.apply(second)
    jobs.returnToContext(second)
    #expect(secondTarget.focusCalls == 0)
    #expect(jobs.jobs.count == 2)
    jobs.dismiss(first)
    #expect(jobs.jobs.count == 1)
    await gate.resolve("write", result: .success("ack"))
    await jobs.wait(for: second)
    #expect(secondTarget.document == "result")
    #expect(secondTarget.writes == 1)
    #expect(jobs.jobs[0].id == second)
    #expect(jobs.jobs[0].applicationState == .applied)
}

@MainActor @Test func focusLossBeforePostingIsBlockedAndCanBeAppliedLater() async throws {
    let target = MemoryTarget("original", selected: "original")
    target.beforeWrite = { throw TargetError.foregroundRequired }
    let jobs = PolishJobs { _ in "result" }
    let id = try jobs.start(target: target)
    await jobs.wait(for: id)
    #expect(jobs.jobs[0].applicationState == .blocked)
    #expect(target.writes == 0)
    target.beforeWrite = nil
    jobs.apply(id)
    await jobs.wait(for: id)
    #expect(target.document == "result")
    #expect(target.writes == 1)
    #expect(jobs.jobs[0].applicationState == .applied)
}

@MainActor @Test func outOfOrderJobsKeepTheirOriginalTargets() async throws {
    let gate = GenerationGate()
    let jobs = PolishJobs { try await gate.generate($0) }
    let a = MemoryTarget("前缀🙂 alpha 后缀", selected: "alpha")
    let b = MemoryTarget("prefix beta suffix", selected: "beta")
    let first = try jobs.start(target: a)
    let second = try jobs.start(target: b)
    a.isFocused = false
    await gate.waitForRequests(2)
    await gate.resolve("beta", result: .success("BETTER B"))
    await jobs.wait(for: second)
    #expect(b.document == "prefix BETTER B suffix")
    #expect(a.document == "前缀🙂 alpha 后缀")
    await gate.resolve("alpha", result: .success("更明确的 A"))
    await jobs.wait(for: first)
    #expect(a.document == "前缀🙂 更明确的 A 后缀")
    #expect(a.focusCalls == 0 && b.focusCalls == 0)
    #expect(!a.isFocused && b.isFocused)
    #expect(jobs.jobs.allSatisfy { $0.applicationState == .applied })
}

@MainActor @Test func duplicateInFlightTaskIsRejected() async throws {
    let gate = GenerationGate()
    let jobs = PolishJobs { try await gate.generate($0) }
    let target = MemoryTarget("original", selected: "original")
    let id = try jobs.start(target: target)
    #expect(throws: TargetError.busy) { try jobs.start(target: target) }
    await gate.waitForRequests(1)
    await gate.resolve("original", result: .success("new"))
    await jobs.wait(for: id)
    #expect(target.writes == 1)
    jobs.apply(id)
    await jobs.wait(for: id)
    #expect(target.writes == 1)
}

@MainActor @Test func changedDocumentBlocksStaleResult() async throws {
    let gate = GenerationGate()
    let jobs = PolishJobs { try await gate.generate($0) }
    let target = MemoryTarget("prefix original", selected: "original")
    let id = try jobs.start(target: target)
    await gate.waitForRequests(1)
    target.document = "prefix user edit"
    await gate.resolve("original", result: .success("new"))
    await jobs.wait(for: id)
    #expect(jobs.jobs[0].applicationState == .blocked)
    #expect(jobs.jobs[0].result == "new")
    #expect(target.document == "prefix user edit" && target.writes == 0)
}

@MainActor @Test func closedTargetNeverRebinds() async throws {
    let gate = GenerationGate()
    let jobs = PolishJobs { try await gate.generate($0) }
    let original = MemoryTarget("text", selected: "text")
    let replacementWindow = MemoryTarget("text", selected: "text")
    let id = try jobs.start(target: original)
    await gate.waitForRequests(1)
    original.valid = false
    await gate.resolve("text", result: .success("result"))
    await jobs.wait(for: id)
    jobs.returnToContext(id)
    #expect(jobs.jobs[0].applicationState == .blocked)
    #expect(original.writes == 0 && replacementWindow.writes == 0)
    #expect(original.focusCalls == 0 && replacementWindow.focusCalls == 0)
}

@MainActor @Test func foregroundOnlyTargetWaitsForExplicitReturnAndApply() async throws {
    let target = MemoryTarget("text", selected: "text")
    target.supportsBackgroundWrite = false
    target.isFocused = false
    let jobs = PolishJobs { _ in "result" }
    let id = try jobs.start(target: target)
    await jobs.wait(for: id)
    #expect(jobs.jobs[0].applicationState == .blocked)
    #expect(target.writes == 0 && target.focusCalls == 0)
    jobs.returnToContext(id)
    #expect(target.focusCalls == 1)
    #expect(!jobs.applyWaitingResult(to: "another-target"))
    #expect(jobs.applyWaitingResult(to: target.id))
    await jobs.wait(for: id)
    #expect(target.document == "result")
    #expect(jobs.jobs[0].applicationState == .applied)
}

@MainActor @Test func expiredWaitingResultStopsClaimingTheKeyAndANewPolishStarts() async throws {
    let target = MemoryTarget("first draft", selected: "first draft")
    target.supportsBackgroundWrite = false
    target.isFocused = false
    let jobs = PolishJobs { "polished " + $0 }
    let first = try jobs.start(target: target)
    await jobs.wait(for: first)
    #expect(jobs.jobs[0].applicationState == .blocked)
    // The user came back, kept typing, and pressed the key again.
    target.isFocused = true
    target.document = "second draft"
    target.range = NSRange(location: 0, length: 12)
    #expect(!jobs.applyWaitingResult(to: target.id))
    #expect(jobs.jobs[0].failure == .target(.conflict))
    #expect(jobs.jobs[0].applicationState == .blocked)
    #expect(target.writes == 0)
    // The same press now polishes the current text; the expired result never claims the key again.
    let second = try jobs.start(target: target)
    await jobs.wait(for: second)
    #expect(target.document == "polished second draft")
    #expect(jobs.jobs[1].applicationState == .applied)
    #expect(!jobs.applyWaitingResult(to: target.id))
    #expect(jobs.jobs[0].result == "polished first draft")
}

@MainActor @Test(arguments: [false, true]) func unverifiedWriteIsNeverRetried(readFails: Bool) async throws {
    let target = MemoryTarget("text", selected: "text")
    target.ignoreWrites = !readFails
    target.failReadsAfterWrite = readFails
    let jobs = PolishJobs { _ in "result" }
    let id = try jobs.start(target: target)
    await jobs.wait(for: id)
    #expect(jobs.jobs[0].applicationState == .uncertain)
    jobs.apply(id)
    await jobs.wait(for: id)
    jobs.undo(id)
    await jobs.wait(for: id)
    #expect(target.writes == 1)
}

@MainActor @Test func undoPreservesLaterSuffixEdits() async throws {
    let target = MemoryTarget("前🙂 原文 后缀", selected: "原文")
    let jobs = PolishJobs { _ in "润色后的段落" }
    let id = try jobs.start(target: target)
    await jobs.wait(for: id)
    target.document += " 用户追加"
    target.isFocused = false
    jobs.undo(id)
    await jobs.wait(for: id)
    #expect(target.document == "前🙂 原文 后缀 用户追加")
    #expect(jobs.jobs[0].applicationState == .undone)
    #expect(target.focusCalls == 0)
    jobs.undo(id)
    await jobs.wait(for: id)
    #expect(target.writes == 2)
}

@MainActor @Test func returnToAppliedContextPreservesLaterSuffixEdits() async throws {
    let target = MemoryTarget("前🙂 原文 后缀", selected: "原文")
    let jobs = PolishJobs { _ in "润色后的段落" }
    let id = try jobs.start(target: target)
    await jobs.wait(for: id)
    target.document += " 用户追加"
    target.isFocused = false
    jobs.returnToContext(id)
    #expect(target.focusCalls == 1)
    #expect(target.isFocused)
    #expect(target.range == NSRange(location: 4, length: 6))
    #expect(target.document == "前🙂 润色后的段落 后缀 用户追加")
    #expect(target.writes == 1)
    #expect(jobs.jobs[0].message == nil)
}

@MainActor @Test(arguments: ["前🙂 用户的新段落 后缀", "新前缀 前🙂 结果 后缀"])
func returnToConflictingContextDoesNotActivate(changed: String) async throws {
    let target = MemoryTarget("前🙂 原文 后缀", selected: "原文")
    let jobs = PolishJobs { _ in "结果" }
    let id = try jobs.start(target: target)
    await jobs.wait(for: id)
    target.document = changed
    target.isFocused = false
    jobs.returnToContext(id)
    #expect(target.focusCalls == 0)
    #expect(!target.isFocused)
    #expect(target.document == changed)
    #expect(target.writes == 1)
    #expect(jobs.jobs[0].message != nil)
}

@MainActor @Test(arguments: ["前🙂 用户的新段落 后缀", "新前缀 前🙂 结果 后缀"])
func undoRefusesModifiedSegmentOrMovedRange(changed: String) async throws {
    let target = MemoryTarget("前🙂 原文 后缀", selected: "原文")
    let jobs = PolishJobs { _ in "结果" }
    let id = try jobs.start(target: target)
    await jobs.wait(for: id)
    target.document = changed
    jobs.undo(id)
    await jobs.wait(for: id)
    #expect(target.document == changed)
    #expect(target.writes == 1)
    #expect(jobs.jobs[0].applicationState == .applied)
    #expect(jobs.jobs[0].message != nil)
}

@MainActor @Test func generationFailureDoesNotWriteAndDismissReleasesRecord() async throws {
    let target = MemoryTarget("text", selected: "text")
    let jobs = PolishJobs { _ in throw PolishError.httpStatus(401) }
    let id = try jobs.start(target: target)
    await jobs.wait(for: id)
    #expect(jobs.jobs[0].computeState == .failed)
    #expect(target.writes == 0)
    jobs.dismiss(id)
    #expect(jobs.jobs.isEmpty)
}

@Test(arguments: [NSRange(location: 2, length: 1), NSRange(location: NSNotFound, length: 1),
                  NSRange(location: 0, length: Int.max), NSRange(location: -1, length: 1)])
func invalidUTF16RangesRejected(range: NSRange) {
    #expect(throws: TargetError.invalidSelection) { try TextSnapshot(document: "a🙂b", range: range) }
}

@Test(arguments: ["e\u{301}", "👩‍💻", "👍🏽"])
func partialComposedCharacterRejected(character: String) {
    #expect(throws: TargetError.invalidSelection) {
        try TextSnapshot(document: character, range: NSRange(location: 0, length: 1))
    }
    #expect(throws: Never.self) {
        try TextSnapshot(document: character, range: NSRange(location: 0, length: (character as NSString).length))
    }
}

@MainActor @Test func backgroundApplyAndUndoLeaveActiveTargetEditingUndisturbed() async throws {
    let gate = GenerationGate()
    let jobs = PolishJobs { try await gate.generate($0) }
    let original = "前缀🙂 原文 后缀"
    let a = MemoryTarget(original, selected: "原文")
    let b = MemoryTarget("B", selected: "B")
    let id = try jobs.start(target: a)
    await gate.waitForRequests(1)
    a.isFocused = false
    b.document += " 用户继续输入"
    await gate.resolve("原文", result: .success("改写结果"))
    await jobs.wait(for: id)
    #expect(jobs.jobs[0].applicationState == .applied)
    #expect(a.document == "前缀🙂 改写结果 后缀")
    jobs.undo(id)
    await jobs.wait(for: id)
    #expect(jobs.jobs[0].applicationState == .undone)
    #expect(a.document == original)
    #expect(!a.isFocused && b.isFocused)
    #expect(a.focusCalls == 0 && b.focusCalls == 0)
    #expect(b.document == "B 用户继续输入" && b.writes == 0)
}

@MainActor @Test func normalizationChangeDuringGenerationDoesNotWriteAtStaleOffset() async throws {
    let gate = GenerationGate()
    let jobs = PolishJobs { try await gate.generate($0) }
    let target = MemoryTarget("é old tail", selected: "old")
    let id = try jobs.start(target: target)
    await gate.waitForRequests(1)
    let changed = "e\u{301} old tail"
    #expect(target.document == changed) // Swift canonical equality hides the offset change.
    target.document = changed
    await gate.resolve("old", result: .success("NEW"))
    await jobs.wait(for: id)
    #expect(target.replaceCalls == 0)
    #expect(target.writes == 0)
    #expect(target.document.utf16.elementsEqual(changed.utf16))
    #expect(jobs.jobs[0].applicationState == .blocked)
    #expect(jobs.jobs[0].message == TargetError.conflict.localizedDescription)
}

@MainActor @Test func canonicalEquivalentNoOpDoesNotCountAsApplied() async throws {
    let target = MemoryTarget("é", selected: "é")
    target.ignoreWrites = true
    let jobs = PolishJobs { _ in "e\u{301}" }
    let id = try jobs.start(target: target)
    await jobs.wait(for: id)
    #expect(target.writes == 1)
    #expect(jobs.jobs[0].applicationState == .uncertain)
    jobs.apply(id)
    await jobs.wait(for: id)
    #expect(target.writes == 1)
}

@MainActor @Test func reorderedCombiningPrefixPreventsUndoAndReturn() async throws {
    let target = MemoryTarget("q\u{301}\u{323} old tail", selected: "old")
    let jobs = PolishJobs { _ in "NEW" }
    let id = try jobs.start(target: target)
    await jobs.wait(for: id)
    let changed = "q\u{323}\u{301} NEW tail"
    #expect(target.document == changed)
    target.document = changed
    target.isFocused = false
    jobs.returnToContext(id)
    #expect(target.focusCalls == 0)
    jobs.undo(id)
    await jobs.wait(for: id)
    #expect(target.writes == 1)
    #expect(target.document.utf16.elementsEqual(changed.utf16))
    #expect(jobs.jobs[0].applicationState == .applied)
    #expect(jobs.jobs[0].message == TargetError.cannotUndo.localizedDescription)
}

@MainActor @Test func normalizationChangePreventsReturningToOriginalSelection() async throws {
    let target = MemoryTarget("é old tail", selected: "old")
    target.supportsBackgroundWrite = false
    target.isFocused = false
    let jobs = PolishJobs { _ in "NEW" }
    let id = try jobs.start(target: target)
    await jobs.wait(for: id)
    target.document = "e\u{301} old tail"
    jobs.returnToContext(id)
    #expect(target.focusCalls == 0)
    #expect(jobs.jobs[0].message == TargetError.conflict.localizedDescription)
}

@MainActor @Test func normalizedUndoReadbackIsUncertain() async throws {
    let target = MemoryTarget("é", selected: "é")
    let jobs = PolishJobs { _ in "NEW" }
    let id = try jobs.start(target: target)
    await jobs.wait(for: id)
    target.afterWrite = { target.document = "e\u{301}" }
    jobs.undo(id)
    await jobs.wait(for: id)
    target.afterWrite = nil
    #expect(jobs.jobs[0].applicationState == .uncertain)
    #expect(target.writes == 2)
    jobs.undo(id)
    await jobs.wait(for: id)
    #expect(target.writes == 2)
}

@Test @MainActor func aJobCarriesTheModelThatAnsweredIt() async throws {
    let target = MemoryTarget("草稿", selected: "草稿")
    let jobs = PolishJobs.completing { _ in Completion(text: "结果", model: "provider-name") }
    let id = try jobs.start(target: target, model: "configured")
    #expect(jobs.jobs.first?.model == "configured")
    await jobs.wait(for: id)
    #expect(jobs.jobs.first?.model == "provider-name")
}

@MainActor @Test func perJobCompletionRetainsItsConfigurationWhileLaterJobsChange() async throws {
    let jobs = PolishJobs { _ in "wrong-default" }
    let first = MemoryTarget("first", selected: "first")
    let second = MemoryTarget("second", selected: "second")
    let a = try jobs.start(target: first, model: "a", completing: { _ in Completion(text: "result-a", model: "a") })
    let b = try jobs.start(target: second, model: "b", completing: { _ in Completion(text: "result-b", model: "b") })
    await jobs.wait(for: a)
    await jobs.wait(for: b)
    #expect(first.document == "result-a")
    #expect(second.document == "result-b")
    #expect(jobs.jobs.map(\.model) == ["a", "b"])
}
