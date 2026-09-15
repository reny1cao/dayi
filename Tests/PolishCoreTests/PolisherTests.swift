import Foundation
import Testing
@testable import PolishCore

private let endpoint = URL(string: "https://example.test/v1/chat/completions")!

private func settings() throws -> ModelConfiguration {
    try ModelConfiguration(endpoint: endpoint, model: "test-model", apiKey: "test-key")
}

private func response(_ body: String, status: Int = 200) -> (Data, HTTPURLResponse) {
    (Data(body.utf8), HTTPURLResponse(url: endpoint, statusCode: status, httpVersion: nil, headerFields: nil)!)
}

@Test(arguments: ["literal-$&-end", "literal-$`-$'-$$", "原文🙂\n{input}\nsecond line", "a\\b\"c"])
func templatePreservesLiteralInput(input: String) throws {
    let template = try PromptTemplate.bundled()
    let parts = template.userPromptTemplate.components(separatedBy: "{input}")
    #expect(parts.count == 2)
    #expect(try template.render(input) == parts[0] + input + parts[1])
}

@Test(arguments: ["", "  ", "\n\t"])
func emptyInputNeverCallsTransport(input: String) async throws {
    let polisher = try Polisher(configuration: settings(), template: .bundled()) { _ in
        Issue.record("Empty input reached network transport")
        return response("{}")
    }
    await #expect(throws: PolishError.emptyInput) { try await polisher.polish(input) }
}

@Test func requestContainsOnlySelectedTextAndTemplate() async throws {
    let template = try PromptTemplate.bundled()
    let polisher = try Polisher(configuration: settings(), template: template) { request in
        #expect(request.url == endpoint)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
        let body = try #require(request.httpBody)
        let payload = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(Set(payload.keys) == ["model", "messages", "stream", "reasoning_effort"])
        #expect(payload["model"] as? String == "test-model")
        #expect(payload["reasoning_effort"] as? String == "low")
        let messages = try #require(payload["messages"] as? [[String: String]])
        #expect(messages == [["role": "system", "content": template.systemPrompt],
                             ["role": "user", "content": try template.render("选中🙂 $&")]])
        return response(#"{"choices":[{"message":{"content":"  “清晰的文本”  "},"finish_reason":"stop"}]}"#)
    }
    #expect(try await polisher.polish("选中🙂 $&") == "“清晰的文本”")
}

@Test(arguments: [401, 429, 500, 302])
func httpFailureDoesNotExposeServerBody(status: Int) async throws {
    let polisher = try Polisher(configuration: settings(), template: .bundled()) { _ in
        response("secret-key and private input", status: status)
    }
    await #expect(throws: PolishError.httpStatus(status)) { try await polisher.polish("输入") }
    #expect(!PolishError.httpStatus(status).localizedDescription.contains("secret"))
}

@Test(arguments: ["{}", "not JSON", #"{"choices":[]}"#, #"{"choices":[{"message":4}]}"#])
func malformedResponsesFail(body: String) async throws {
    let polisher = try Polisher(configuration: settings(), template: .bundled()) { _ in response(body) }
    await #expect(throws: PolishError.invalidResponse) { try await polisher.polish("输入") }
}

@Test(arguments: ["length", "content_filter", "tool_calls"])
func unfinishedOrNonTextCompletionRejected(reason: String) async throws {
    let polisher = try Polisher(configuration: settings(), template: .bundled()) { _ in
        response("{\"choices\":[{\"message\":{\"content\":\"partial\"},\"finish_reason\":\"\(reason)\"}]}")
    }
    await #expect(throws: PolishError.incompleteResult) { try await polisher.polish("输入") }
}

@Test(arguments: ["null", "\"   \""])
func blankModelResultRejected(content: String) async throws {
    let polisher = try Polisher(configuration: settings(), template: .bundled()) { _ in
        response("{\"choices\":[{\"message\":{\"content\":\(content)},\"finish_reason\":\"stop\"}]}")
    }
    await #expect(throws: PolishError.emptyResult) { try await polisher.polish("输入") }
}

@Test func cancellationPropagatesWithoutRetry() async throws {
    let polisher = try Polisher(configuration: settings(), template: .bundled()) { _ in throw CancellationError() }
    await #expect(throws: CancellationError.self) { try await polisher.polish("输入") }
}

@Test(arguments: ["http://example.test/v1", "https://key@example.test/v1", "https://example.test/v1?key=secret"])
func rejectsUnsafeEndpoint(raw: String) {
    #expect(throws: PolishError.self) {
        try ModelConfiguration(endpoint: URL(string: raw)!, model: "model", apiKey: "test")
    }
}

@Test func missingConfigurationFailsLocally() {
    #expect(throws: PolishError.self) { try ModelConfiguration.environment([:]) }
    #expect(throws: PolishError.self) { try ModelConfiguration(endpoint: endpoint, model: " ", apiKey: "test") }
    #expect(throws: PolishError.self) { try ModelConfiguration(endpoint: endpoint, model: "model", apiKey: "test\nother") }
}

@Test(arguments: ["“正文”", "'正文", "正文’", "\"\"", "```text\n正文\n```", "e\u{301}🙂"])
func cleanupPreservesMeaningfulQuotesAndFormatting(text: String) {
    #expect(PromptTemplate.clean(" \n" + text + "\n ").utf16.elementsEqual(text.utf16))
}

@Test(arguments: [nil, "", "  ", "none"])
func reasoningEffortCanBeLeftOut(effort: String?) async throws {
    let configuration = try ModelConfiguration(endpoint: endpoint, model: "m", apiKey: "k", reasoningEffort: effort)
    #expect(configuration.reasoningEffort == nil)
    let polisher = try Polisher(configuration: configuration, template: .bundled()) { request in
        let body = try #require(request.httpBody)
        let payload = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(payload["reasoning_effort"] == nil)
        return response(#"{"choices":[{"message":{"content":"ok"},"finish_reason":"stop"}]}"#)
    }
    #expect(try await polisher.polish("输入") == "ok")
}

@Test func reasoningEffortComesFromTheEnvironmentWithLowAsDefault() throws {
    let base = ["POLISH_ENDPOINT": endpoint.absoluteString, "POLISH_MODEL": "m", "POLISH_API_KEY": "k"]
    #expect(try ModelConfiguration.environment(base).reasoningEffort == "low")
    #expect(try ModelConfiguration.environment(base.merging(["POLISH_REASONING_EFFORT": "high"]) { $1 }).reasoningEffort == "high")
    #expect(try ModelConfiguration.environment(base.merging(["POLISH_REASONING_EFFORT": "none"]) { $1 }).reasoningEffort == nil)
}

@Test func thinkingIsOnlySentWhenDisabled() async throws {
    let base = ["POLISH_ENDPOINT": endpoint.absoluteString, "POLISH_MODEL": "m", "POLISH_API_KEY": "k"]
    #expect(try ModelConfiguration.environment(base).disablesThinking == false)
    let configuration = try ModelConfiguration.environment(base.merging(["POLISH_THINKING": "disabled"]) { $1 })
    #expect(configuration.disablesThinking)
    let polisher = try Polisher(configuration: configuration, template: .bundled()) { request in
        let body = try #require(request.httpBody)
        let payload = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(payload["thinking"] as? [String: String] == ["type": "disabled"])
        return response(#"{"choices":[{"message":{"content":"ok"},"finish_reason":"stop"}]}"#)
    }
    #expect(try await polisher.polish("输入") == "ok")
}
