import Foundation
import Testing
@testable import PolishCore

private func directoryResponse(_ request: URLRequest, _ body: String, status: Int = 200) -> (Data, HTTPURLResponse) {
    (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
}

@Test func compatibleModelListingUsesExactBaseAndNoDraftOrCredentialsInURL() async throws {
    let directory = ModelDirectory { request in
        #expect(request.url!.absoluteString == "https://custom.example/gateway/v1/models")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-key")
        #expect(request.httpBody == nil)
        return directoryResponse(request, #"{"data":[{"id":"deployment-b"},{"id":"deployment-a"},{"id":"deployment-a"}]}"#)
    }
    let models = try await directory.models(endpoint: "https://custom.example/gateway/v1/chat/completions", apiKey: "synthetic-key")
    #expect(models.map(\.id) == ["deployment-a", "deployment-b"])
}

@Test func anthropicPaginationKeepsOriginAndDedicatedHeaders() async throws {
    let directory = ModelDirectory { request in
        #expect(request.url!.host == "api.anthropic.com")
        #expect(request.url!.path == "/v1/models")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "synthetic-key")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        if request.url!.query == nil {
            return directoryResponse(request, #"{"data":[{"id":"a","display_name":"A"}],"has_more":true,"last_id":"https://evil.example/?secret"}"#)
        }
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
        #expect(query == [URLQueryItem(name: "after_id", value: "https://evil.example/?secret")])
        return directoryResponse(request, #"{"data":[{"id":"b"}],"has_more":false}"#)
    }
    let models = try await directory.models(endpoint: "https://api.anthropic.com/v1/chat/completions", apiKey: "synthetic-key")
    #expect(models.map(\.id) == ["a", "b"])
}

@Test func geminiUsesOfficialListAndFiltersNonGeneratingModels() async throws {
    let directory = ModelDirectory { request in
        #expect(request.url!.path == "/v1beta/models")
        #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == "synthetic-key")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        if request.url!.query == nil {
            return directoryResponse(request, #"{"models":[{"name":"models/embedding","supportedGenerationMethods":["embedContent"]}],"nextPageToken":"page2"}"#)
        }
        #expect(request.url!.query == "pageToken=page2")
        return directoryResponse(request, #"{"models":[{"name":"models/gemini-test","displayName":"Test","supportedGenerationMethods":["generateContent"]}]}"#)
    }
    let models = try await directory.models(endpoint: "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions", apiKey: "synthetic-key")
    #expect(models.map(\.id) == ["gemini-test"])
}

@Test func directoryRejectsBadBoundaryDataAndDoesNotExposeResponseSecrets() async throws {
    let noRequests = ModelDirectory { _ in Issue.record("Invalid boundary sent a request"); throw PolishError.invalidResponse }
    await #expect(throws: PolishError.self) { try await noRequests.models(endpoint: "http://example.test/chat/completions", apiKey: "k") }
    await #expect(throws: PolishError.self) { try await noRequests.models(endpoint: "https://example.test/chat/completions?key=secret", apiKey: "k") }
    await #expect(throws: PolishError.self) { try await noRequests.models(endpoint: "https://example.test/chat/completions", apiKey: "k\nheader") }
    for status in [301, 401, 403, 404, 429, 500] {
        let service = ModelDirectory { request in directoryResponse(request, "secret-echo", status: status) }
        await #expect(throws: PolishError.httpStatus(status)) { try await service.models(endpoint: "https://example.test/chat/completions", apiKey: "k") }
    }
    for body in [#"{"data":[{"id":""}]}"#, #"{"data":null}"#, #"{"data":[],"has_more":true}"#, #"{"data":[],"has_more":true,"last_id":"same"}"#] {
        let service = ModelDirectory { request in directoryResponse(request, body) }
        await #expect(throws: PolishError.invalidResponse) { try await service.models(endpoint: "https://example.test/chat/completions", apiKey: "k") }
    }
}

@Test func cancelledDirectoryRequestDoesNotPublishResponse() async throws {
    let directory = ModelDirectory { request in
        withUnsafeCurrentTask { $0?.cancel() }
        return directoryResponse(request, #"{"data":[{"id":"stale"}]}"#)
    }
    let task = Task { try await directory.models(endpoint: "https://example.test/chat/completions", apiKey: "k") }
    await #expect(throws: CancellationError.self) { try await task.value }
}
