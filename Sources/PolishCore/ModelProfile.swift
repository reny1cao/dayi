import Foundation

/// What a person configures: which model, where it lives, and how it is asked. The key is not
/// part of it; the key lives in the keychain and is joined in when a configuration is built.
public struct ModelProfile: Codable, Sendable, Equatable {
    public enum ThinkingMode: String, Codable, Sendable, CaseIterable {
        /// Send nothing; the provider decides.
        case auto
        /// Send `thinking: {type: disabled}`, the switch DeepSeek and Kimi honour.
        case disabled
    }

    /// A display name; empty falls back to the model id.
    public var name: String
    public var endpoint: String
    public var model: String
    /// `reasoning_effort`; empty omits the field. GLM-5.3 honours it, DeepSeek and Kimi ignore it.
    public var reasoningEffort: String
    public var thinking: ThinkingMode
    /// A JSON object merged into the request body, for anything a provider wants that the
    /// fields above do not cover (temperature, max_tokens, a provider-specific switch).
    public var extraParameters: String

    public init(name: String = "", endpoint: String = "", model: String = "", reasoningEffort: String = "low",
                thinking: ThinkingMode = .auto, extraParameters: String = "") {
        self.name = name
        self.endpoint = endpoint
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.thinking = thinking
        self.extraParameters = extraParameters
    }

    public var label: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? model.trimmingCharacters(in: .whitespacesAndNewlines) : trimmed
    }

    /// Joins the key in and validates everything the way the environment path always has.
    public func configuration(apiKey: String) throws -> ModelConfiguration {
        guard let url = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw PolishError.invalidConfiguration("模型地址")
        }
        return try ModelConfiguration(endpoint: url, model: model, apiKey: apiKey,
                                      reasoningEffort: reasoningEffort, disablesThinking: thinking == .disabled,
                                      extraParametersJSON: extraParameters)
    }

    /// The environment variables the launcher sets, read as a profile so a saved profile and
    /// a launch flag are the same thing to the rest of the app.
    public static func environment(_ values: [String: String] = ProcessInfo.processInfo.environment) -> ModelProfile? {
        guard let endpoint = values["POLISH_ENDPOINT"], let model = values["POLISH_MODEL"] else { return nil }
        return ModelProfile(endpoint: endpoint, model: model,
                            reasoningEffort: values["POLISH_REASONING_EFFORT"] ?? "low",
                            thinking: values["POLISH_THINKING"] == "disabled" ? .disabled : .auto,
                            extraParameters: values["POLISH_EXTRA_PARAMETERS"] ?? "")
    }

}

/// One answer from the model: the text, and the model the provider says produced it. The
/// provider's name wins over the configured one when both exist, because a gateway may route
/// a request somewhere else and the record should say where it actually went.
public struct Completion: Sendable, Equatable {
    public let text: String
    public let model: String
    public init(text: String, model: String) {
        self.text = text
        self.model = model
    }
}

/// One entry of the bundled provider catalogue: a profile plus what a person needs to get a
/// key and to know how far the entry has been checked.
public struct ProviderPreset: Codable, Sendable, Equatable, Identifiable {
    public let name: String
    public let category: String
    public let endpoint: String
    public let model: String
    public let reasoningEffort: String
    public let thinking: ModelProfile.ThinkingMode
    public let extraParameters: String
    public let website: String?
    public let apiKeyURL: String?
    /// Other model ids the provider lists; the profile starts on `model`.
    public let models: [String]
    /// True when this exact endpoint and thinking setting completed a polish from Dayi.
    public let verified: Bool
    /// The latency range this project measured, in seconds, as a range like "1.6–4.0";
    /// nil for the 39 entries that have never had a request sent to them. Views add the unit.
    public let measured: String?
    public let note: String
    /// File name inside the bundled `icons` folder; nil where the provider has no logo.
    public let icon: String?

    public var id: String { name }

    public var profile: ModelProfile {
        ModelProfile(name: name, endpoint: endpoint, model: model, reasoningEffort: reasoningEffort,
                     thinking: thinking, extraParameters: extraParameters)
    }
}

/// The catalogue is data, not code: adding a provider is one JSON entry. It is derived from
/// CC Switch's Codex preset list (MIT) plus the endpoints this project has used itself; the
/// `source` block records which revision, so a refresh can be diffed.
public struct ProviderCatalog: Codable, Sendable, Equatable {
    public struct Source: Codable, Sendable, Equatable {
        public let repo: String
        public let file: String
        public let commit: String
        public let date: String
        public let license: String
    }

    public let source: Source
    /// Category key to display name, in the order the picker shows them.
    public let categories: [String: String]
    public let providers: [ProviderPreset]

    public static let categoryOrder = ["official", "cn_official", "aggregator", "third_party"]

    public static func bundled() throws -> ProviderCatalog {
        try JSONDecoder().decode(ProviderCatalog.self, from: Data(contentsOf: try PolishResources.url("providers", "json")))
    }

    /// The logo file for a preset, if the catalogue has one and the bundle carries it.
    public func iconURL(for preset: ProviderPreset) -> URL? {
        guard let icon = preset.icon else { return nil }
        let name = (icon as NSString).deletingPathExtension
        let ext = (icon as NSString).pathExtension
        return try? PolishResources.url(name, ext, subdirectory: "icons")
    }

    /// The preset a saved profile came from: same name first, else the same endpoint.
    public func preset(matching profile: ModelProfile) -> ProviderPreset? {
        providers.first { $0.name == profile.name } ?? providers.first { $0.endpoint == profile.endpoint }
    }

    /// Providers grouped for a menu, categories in the fixed order, names sorted within.
    public var sections: [(category: String, title: String, providers: [ProviderPreset])] {
        Self.categoryOrder.compactMap { key in
            let members = providers.filter { $0.category == key }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            guard !members.isEmpty else { return nil }
            return (key, categories[key] ?? key, members)
        }
    }
}
