import Foundation

public struct PromptTemplate: Decodable, Sendable {
    public let sourceVersion: String
    public let systemPrompt: String
    public let userPromptTemplate: String

    public init(systemPrompt: String, userPromptTemplate: String, sourceVersion: String) throws {
        self.systemPrompt = systemPrompt
        self.userPromptTemplate = userPromptTemplate
        self.sourceVersion = sourceVersion
        try validate()
    }

    public func validate() throws {
        guard !systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PolishError.invalidConfiguration("系统提示词不能为空")
        }
        guard userPromptTemplate.components(separatedBy: "{input}").count == 2 else {
            throw PolishError.invalidConfiguration("用户提示词必须包含且仅包含一个 {input}")
        }
    }

    // Keep the resource in memory for the process lifetime. A replaced app bundle must not
    // change the template used by an already-running process on its next keypress.
    private static let bundledTemplate: Result<Self, Error> = Result {
        let template = try JSONDecoder().decode(Self.self, from: Data(contentsOf: PolishResources.url("default-polish-template", "json")))
        try template.validate()
        return template
    }

    public static func bundled() throws -> Self {
        try bundledTemplate.get()
    }

    public func render(_ input: String) throws -> String {
        guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PolishError.emptyInput
        }
        guard let range = userPromptTemplate.range(of: "{input}") else {
            throw PolishError.invalidConfiguration("模板占位符")
        }
        // Range replacement treats the input literally, including $&, $' and {input}.
        var rendered = userPromptTemplate
        rendered.replaceSubrange(range, with: input)
        return rendered
    }

    /// Boundary whitespace is transport noise; quotes and formatting may belong to the draft.
    public static func clean(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// The module's bundled files, found the same way whether the code runs from a packaged app
/// (where the bundle sits in Contents/Resources) or from SwiftPM development runs and tests.
enum PolishResources {
    static func url(_ name: String, _ ext: String, subdirectory: String? = nil) throws -> URL {
        let resources: Bundle
        if Bundle.main.bundleURL.pathExtension == "app" {
            guard let resourceURL = Bundle.main.resourceURL?.appendingPathComponent("TextPolish_PolishCore.bundle"),
                  let bundle = Bundle(url: resourceURL) else { throw PolishError.invalidConfiguration("应用资源包") }
            resources = bundle
        } else {
            resources = Bundle.module
        }
        guard let url = resources.url(forResource: name, withExtension: ext, subdirectory: subdirectory) else {
            throw PolishError.invalidConfiguration("资源 \(name).\(ext)")
        }
        return url
    }
}
