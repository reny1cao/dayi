import Foundation
import Testing
@testable import PolishCore

@Test func bundledCatalogueLoadsAndEveryEntryBuildsARequestConfiguration() throws {
    let catalog = try ProviderCatalog.bundled()
    #expect(catalog.providers.count >= 40)
    #expect(catalog.source.repo == "farion1231/cc-switch")
    var names: Set<String> = []
    for preset in catalog.providers {
        #expect(names.insert(preset.name).inserted, "duplicate preset \(preset.name)")
        #expect(preset.endpoint.hasPrefix("https://") && preset.endpoint.hasSuffix("/chat/completions"), Comment(rawValue: preset.name))
        #expect(!preset.model.isEmpty, Comment(rawValue: preset.name))
        #expect(catalog.categories[preset.category] != nil, "unknown category for \(preset.name)")
        let configuration = try preset.profile.configuration(apiKey: "k")
        #expect(configuration.model == preset.model)
    }
}

@Test func sectionsFollowTheFixedCategoryOrder() throws {
    let sections = try ProviderCatalog.bundled().sections
    #expect(sections.map(\.category) == ProviderCatalog.categoryOrder.filter { key in sections.contains { $0.category == key } })
    #expect(sections.first?.category == "official")
    for section in sections {
        #expect(section.providers.map(\.name) == section.providers.map(\.name).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })
    }
}

@Test func verifiedEntriesMatchWhatWasMeasured() throws {
    let catalog = try ProviderCatalog.bundled()
    let deepseek = try #require(catalog.providers.first { $0.name == "DeepSeek" })
    #expect(deepseek.verified && deepseek.thinking == .disabled && deepseek.reasoningEffort.isEmpty)
    let glm = try #require(catalog.providers.first { $0.name == "GLM-5.3 (sophnet)" })
    #expect(glm.verified && glm.reasoningEffort == "low" && glm.thinking == .auto)
}

/// `measured` was added after the catalogue shipped. Nothing may require it: 39 of the 42
/// entries have never had a request sent to them, and a stored catalogue written before the
/// field existed still has to decode.
@Test func onlyMeasuredEntriesCarryALatencyRange() throws {
    let catalog = try ProviderCatalog.bundled()
    for preset in catalog.providers {
        #expect((preset.measured != nil) == preset.verified, Comment(rawValue: preset.name))
    }
    #expect(catalog.providers.filter { $0.measured != nil }.count == 3)

    let withoutTheField = """
    {"name": "X", "category": "official", "endpoint": "https://x.test/chat/completions",
     "model": "m", "reasoningEffort": "", "thinking": "auto", "extraParameters": "",
     "models": [], "verified": false, "note": ""}
    """
    let decoded = try JSONDecoder().decode(ProviderPreset.self, from: Data(withoutTheField.utf8))
    #expect(decoded.measured == nil)
}

@Test func everyReferencedIconIsInTheBundle() throws {
    let catalog = try ProviderCatalog.bundled()
    var withIcon = 0
    for preset in catalog.providers where preset.icon != nil {
        withIcon += 1
        let url = try #require(catalog.iconURL(for: preset), Comment(rawValue: preset.name))
        #expect(FileManager.default.fileExists(atPath: url.path), Comment(rawValue: preset.name))
    }
    #expect(withIcon >= 38)
}
