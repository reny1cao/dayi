import Foundation

/// A list response describes availability, not a successful Dayi completion.
public struct AvailableModel: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
}

public struct ModelDirectory: Sendable {
    private let transport: Polisher.Transport

    public init(transport: @escaping Polisher.Transport = Polisher.request) {
        self.transport = transport
    }

    public func models(endpoint: String, apiKey: String) async throws -> [AvailableModel] {
        // Reuse the request boundary's HTTPS / URL-credential / header validation. Listing
        // intentionally does not require the user to know a model ID yet.
        let config = try ModelProfile(endpoint: endpoint, model: "listing").configuration(apiKey: apiKey)
        let host = config.endpoint.host!
        let anthropic = host == "api.anthropic.com"
        let gemini = host == "generativelanguage.googleapis.com"
        var components = URLComponents(url: config.endpoint, resolvingAgainstBaseURL: false)!
        if anthropic {
            components.path = "/v1/models"
        } else if gemini {
            components.path = "/v1beta/models"
        } else {
            guard components.path.hasSuffix("/chat/completions") else {
                throw PolishError.invalidConfiguration("模型列表需要 Chat Completions 地址；不支持列表的服务可手动输入模型 ID")
            }
            components.path = String(components.path.dropLast("chat/completions".count)) + "models"
        }
        var result: [AvailableModel] = []
        var seenIDs = Set<String>()
        var cursors = Set<String>()
        var next: String?
        repeat {
            try Task.checkCancellation()
            components.queryItems = next.map { [URLQueryItem(name: gemini ? "pageToken" : "after_id", value: $0)] }
            var request = URLRequest(url: components.url!)
            request.timeoutInterval = 30
            if anthropic {
                request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
                request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            } else if gemini {
                request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
            } else {
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            }
            let (data, response) = try await transport(request)
            try Task.checkCancellation()
            guard (200..<300).contains(response.statusCode) else { throw PolishError.httpStatus(response.statusCode) }
            let page: [AvailableModel]
            if gemini {
                guard let decoded = try? JSONDecoder().decode(GeminiPage.self, from: data) else { throw PolishError.invalidResponse }
                page = decoded.models.filter { $0.supportedGenerationMethods.contains("generateContent") }.map {
                    AvailableModel(id: $0.name.hasPrefix("models/") ? String($0.name.dropFirst(7)) : $0.name,
                                   name: $0.displayName ?? $0.name)
                }
                next = decoded.nextPageToken
            } else {
                guard let decoded = try? JSONDecoder().decode(CompatiblePage.self, from: data) else { throw PolishError.invalidResponse }
                page = decoded.data.map { AvailableModel(id: $0.id, name: $0.display_name ?? $0.id) }
                if decoded.has_more == true {
                    guard let last = decoded.last_id, !last.isEmpty else { throw PolishError.invalidResponse }
                    next = last
                } else { next = nil }
            }
            for model in page {
                guard !model.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw PolishError.invalidResponse }
                if seenIDs.insert(model.id).inserted { result.append(model) }
            }
            if let next {
                guard !next.isEmpty, cursors.insert(next).inserted else { throw PolishError.invalidResponse }
            }
        } while next != nil
        return result.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }
}

private struct CompatiblePage: Decodable {
    struct Entry: Decodable { let id: String; let display_name: String? }
    let data: [Entry]
    let has_more: Bool?
    let last_id: String?
}
private struct GeminiPage: Decodable {
    struct Entry: Decodable {
        let name: String
        let displayName: String?
        let supportedGenerationMethods: [String]
    }
    let models: [Entry]
    let nextPageToken: String?
}
