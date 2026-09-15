import Foundation
import Testing
@testable import PolishCore

private let endpoint = URL(string: "https://example.test/v1/chat/completions")!

private func response(_ body: String) -> (Data, HTTPURLResponse) {
    (Data(body.utf8), HTTPURLResponse(url: endpoint, statusCode: 200, httpVersion: nil, headerFields: nil)!)
}

@Test func profileRoundTripsThroughJSONAndBuildsAConfiguration() throws {
    let profile = ModelProfile(name: "DS", endpoint: endpoint.absoluteString, model: "deepseek-v4-pro",
                               reasoningEffort: "", thinking: .disabled, extraParameters: #"{"temperature": 0.3}"#)
    let decoded = try JSONDecoder().decode(ModelProfile.self, from: try JSONEncoder().encode(profile))
    #expect(decoded == profile)
    let configuration = try decoded.configuration(apiKey: "k")
    #expect(configuration.model == "deepseek-v4-pro")
    #expect(configuration.reasoningEffort == nil)
    #expect(configuration.disablesThinking)
    #expect(configuration.extraParameters["temperature"] as? Double == 0.3)
    #expect(profile.label == "DS")
    #expect(ModelProfile(model: "m").label == "m")
}

@Test func profileRejectsWhatARequestWouldReject() {
    #expect(throws: PolishError.self) { try ModelProfile(endpoint: "not a url", model: "m").configuration(apiKey: "k") }
    #expect(throws: PolishError.self) { try ModelProfile(endpoint: endpoint.absoluteString, model: "m").configuration(apiKey: " ") }
    #expect(throws: PolishError.self) {
        try ModelProfile(endpoint: endpoint.absoluteString, model: "m", extraParameters: "[1, 2]").configuration(apiKey: "k")
    }
}

@Test func environmentBecomesAProfile() {
    #expect(ModelProfile.environment([:]) == nil)
    let profile = ModelProfile.environment(["POLISH_ENDPOINT": endpoint.absoluteString, "POLISH_MODEL": "m",
                                            "POLISH_THINKING": "disabled", "POLISH_REASONING_EFFORT": "none"])
    #expect(profile == ModelProfile(endpoint: endpoint.absoluteString, model: "m", reasoningEffort: "none", thinking: .disabled))
}

@Test func extraParametersCannotReplaceTheFieldsTheAppOwns() async throws {
    let extras = #"{"temperature": 0.2, "messages": "hijack", "stream": true, "model": "other"}"#
    let configuration = try ModelConfiguration(endpoint: endpoint, model: "m", apiKey: "k", extraParametersJSON: extras)
    let polisher = try Polisher(configuration: configuration, template: .bundled()) { request in
        let body = try #require(request.httpBody)
        let payload = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(payload["temperature"] as? Double == 0.2)
        #expect(payload["model"] as? String == "m")
        #expect(payload["stream"] as? Bool == false)
        #expect((payload["messages"] as? [[String: String]])?.count == 2)
        return response(#"{"model":"m-2024","choices":[{"message":{"content":"ok"},"finish_reason":"stop"}]}"#)
    }
    let completion = try await polisher.complete("输入")
    #expect(completion == Completion(text: "ok", model: "m-2024"))
}

@Test func configuredModelNamesTheResultWhenTheProviderDoesNot() async throws {
    let polisher = try Polisher(configuration: ModelConfiguration(endpoint: endpoint, model: "m", apiKey: "k"),
                                template: .bundled()) { _ in
        response(#"{"choices":[{"message":{"content":"ok"},"finish_reason":"stop"}]}"#)
    }
    #expect(try await polisher.complete("输入").model == "m")
}
