import Foundation
import Testing
@testable import PolishCore

private struct DraftCase: Codable {
    let id: String
    let draft: String
    let mustKeep: [String]
}

private func draftCases() throws -> [DraftCase] {
    let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Fixtures/DefaultPrompt.json")
    return try JSONDecoder().decode([DraftCase].self, from: Data(contentsOf: file))
}

@Test func bundledDefaultRendersSyntheticDraftsLiterally() throws {
    let template = try PromptTemplate.bundled()
    #expect(template.sourceVersion == "dayi-default-1")
    let parts = template.userPromptTemplate.components(separatedBy: "{input}")
    #expect(parts.count == 2)
    for entry in try draftCases() {
        #expect(try template.render(entry.draft).utf16.elementsEqual((parts[0] + entry.draft + parts[1]).utf16))
    }
}

/// Opt-in paid requests using the real production transport. Results still need human
/// semantic review: retaining tokens alone cannot prove a faithful edit.
@Test(.enabled(if: ProcessInfo.processInfo.environment["POLISH_LIVE_DEFAULT_PROMPT"] == "1"))
func liveDefaultPromptOnSyntheticDrafts() async throws {
    struct Result: Codable {
        let id: String
        let draft: String
        let output: String
        let model: String
        let missingTerms: [String]
    }
    let destination = try #require(ProcessInfo.processInfo.environment["POLISH_EVAL_OUTPUT"])
    let polisher = try Polisher(configuration: .environment(), template: .bundled())
    var results: [Result] = []
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    for entry in try draftCases() {
        let answer = try await polisher.complete(entry.draft)
        let missing = entry.mustKeep.filter { !answer.text.localizedCaseInsensitiveContains($0) }
        results.append(Result(id: entry.id, draft: entry.draft, output: answer.text,
                              model: answer.model, missingTerms: missing))
        try encoder.encode(results).write(to: URL(fileURLWithPath: destination), options: .atomic)
        #expect(missing.isEmpty, "Missing literal review terms for \(entry.id): \(missing)")
    }
}
