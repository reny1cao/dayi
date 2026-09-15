import Foundation

public struct ModelConfiguration: Sendable {
    public let endpoint: URL
    public let model: String
    let apiKey: String
    /// Sent as `reasoning_effort`. A reasoning model spends most of its output on thinking by
    /// default (GLM-5.3: 900–1500 reasoning tokens for a 100-token rewrite, 18–37 s); `low`
    /// drops that to zero for this task. Nil omits the field for providers that reject it.
    public let reasoningEffort: String?
    /// Sent as `thinking: {type: disabled}` when true. DeepSeek and Kimi ignore
    /// `reasoning_effort` and only stop thinking through this field; GLM-5.3 rejects it.
    public let disablesThinking: Bool
    /// Extra request fields as one JSON object, already validated. Merged under the fields the
    /// app owns: it can add `temperature`, it cannot replace `messages`.
    public let extraParameters: [String: any Sendable]

    public init(endpoint: URL, model: String, apiKey: String, reasoningEffort: String? = "low",
                disablesThinking: Bool = false, extraParametersJSON: String = "") throws {
        // The first provider is HTTPS Chat Completions; credentials never belong in URLs.
        guard endpoint.scheme == "https", endpoint.host != nil,
              endpoint.user == nil, endpoint.password == nil,
              endpoint.query == nil, endpoint.fragment == nil else {
            throw PolishError.invalidConfiguration("POLISH_ENDPOINT 必须为不含凭据或查询参数的 HTTPS URL")
        }
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PolishError.invalidConfiguration("POLISH_MODEL")
        }
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !apiKey.contains("\r"), !apiKey.contains("\n") else {
            throw PolishError.invalidConfiguration("POLISH_API_KEY")
        }
        self.endpoint = endpoint
        self.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        self.apiKey = apiKey
        let effort = reasoningEffort?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.reasoningEffort = effort.isEmpty || effort == "none" ? nil : effort
        self.disablesThinking = disablesThinking
        let extras = extraParametersJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        if extras.isEmpty {
            extraParameters = [:]
        } else {
            guard let object = try? JSONSerialization.jsonObject(with: Data(extras.utf8)) as? [String: Any] else {
                throw PolishError.invalidConfiguration("额外参数必须是 JSON 对象")
            }
            extraParameters = object.mapValues { $0 as! any Sendable }
        }
    }

    public static func environment(_ values: [String: String] = ProcessInfo.processInfo.environment) throws -> Self {
        guard let raw = values["POLISH_ENDPOINT"], let endpoint = URL(string: raw) else {
            throw PolishError.invalidConfiguration("POLISH_ENDPOINT")
        }
        // Unset keeps the default; "none" turns the field off. POLISH_THINKING=disabled adds the
        // thinking field for providers that need it.
        return try Self(endpoint: endpoint, model: values["POLISH_MODEL"] ?? "", apiKey: values["POLISH_API_KEY"] ?? "",
                        reasoningEffort: values["POLISH_REASONING_EFFORT"] ?? "low",
                        disablesThinking: values["POLISH_THINKING"] == "disabled",
                        extraParametersJSON: values["POLISH_EXTRA_PARAMETERS"] ?? "")
    }
}
