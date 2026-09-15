import Foundation

public struct Polisher: Sendable {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    private let configuration: ModelConfiguration
    private let template: PromptTemplate
    private let transport: Transport

    public init(configuration: ModelConfiguration, template: PromptTemplate, transport: @escaping Transport = Self.request) {
        self.configuration = configuration
        self.template = template
        self.transport = transport
    }

    public func polish(_ text: String) async throws -> String {
        try await complete(text).text
    }

    public func complete(_ text: String) async throws -> Completion {
        let userPrompt = try template.render(text)
        var request = URLRequest(url: configuration.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body(userPrompt: userPrompt))
        let (data, response) = try await transport(request)
        guard (200..<300).contains(response.statusCode) else {
            // Server bodies may echo credentials or user text; do not expose them as diagnostics.
            throw PolishError.httpStatus(response.statusCode)
        }
        guard let decoded = try? JSONDecoder().decode(CompletionResponse.self, from: data),
              let choice = decoded.choices.first else { throw PolishError.invalidResponse }
        guard choice.finish_reason == "stop" else { throw PolishError.incompleteResult }
        guard let content = choice.message.content else { throw PolishError.emptyResult }
        let cleaned = PromptTemplate.clean(content)
        guard !cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw PolishError.emptyResult }
        let reported = decoded.model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return Completion(text: cleaned, model: reported.isEmpty ? configuration.model : reported)
    }

    /// The fields the app owns are written last, so an extra parameter can never redirect the
    /// prompt or turn on streaming, which the response parser does not read.
    private func body(userPrompt: String) -> [String: Any] {
        var body: [String: Any] = configuration.extraParameters
        if let effort = configuration.reasoningEffort { body["reasoning_effort"] = effort }
        if configuration.disablesThinking { body["thinking"] = ["type": "disabled"] }
        body["model"] = configuration.model
        body["messages"] = [["role": "system", "content": template.systemPrompt],
                            ["role": "user", "content": userPrompt]]
        body["stream"] = false
        return body
    }

    /// One session for the process: a request reuses the previous request's connection instead
    /// of opening and handshaking a new one. It still keeps no cache and no cookies.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        return URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }()

    public static func request(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw PolishError.invalidResponse }
        return (data, response)
    }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private struct CompletionResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable { let content: String? }
        let message: Message
        let finish_reason: String?
    }
    let choices: [Choice]
    let model: String?
}
