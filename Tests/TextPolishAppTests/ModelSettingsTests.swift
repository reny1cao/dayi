import Foundation
import Testing
import PolishCore
import PolishStore
@testable import TextPolishApp

private actor ModelPreferences: PreferenceStore {
    var values: [String: String] = [:]
    var fails = false
    func value(forKey key: String) -> String? { values[key] }
    func set(_ value: String?, forKey key: String) throws {
        if fails { throw PolishError.invalidResponse }
        values[key] = value
    }
    func failWrites() { fails = true }
}

@MainActor private final class ModelKeys {
    var values: [String: String] = [:]
    func settings(environment: [String: String] = [:]) -> ModelSettings {
        ModelSettings(environment: environment, readKey: { self.values[$0] }, writeKey: { self.values[$0] = $1 }, deleteKey: { self.values.removeValue(forKey: $0) })
    }
}

@MainActor @Test func savedProvidersKeepSeparateCredentialsAcrossSaveSwitchAndRestart() async throws {
    let store = ModelPreferences()
    let keys = ModelKeys()
    let settings = keys.settings()
    await settings.attach(store)
    let first = ModelProfile(name: "Custom One", endpoint: "https://one.example/v1/chat/completions", model: "one")
    let second = ModelProfile(name: "Custom Two", endpoint: "https://two.example/chat/completions", model: "two")
    try await settings.save(first, apiKey: "key-one")
    let firstID = settings.activeID!
    try await settings.save(second, apiKey: "key-two")
    #expect(settings.profiles.count == 2)
    #expect(settings.apiKey == "key-two")
    let saved = settings.profiles.first { $0.id == firstID }!
    #expect(settings.key(for: saved) == "key-one")
    try await settings.save(saved.profile, apiKey: settings.key(for: saved), id: saved.id)
    #expect(settings.profiles.count == 2)
    let restarted = keys.settings()
    await restarted.attach(store)
    #expect(restarted.activeID == firstID)
    #expect(restarted.apiKey == "key-one")
    #expect(restarted.profiles.count == 2)
    let json = try #require(await store.value(forKey: ModelSettings.collectionKey))
    #expect(!json.contains("key-one"))
    #expect(!json.contains("key-two"))
}

@MainActor @Test func legacyProfileMigratesWithoutUsingEnvironmentKeyOrLosingOriginal() async throws {
    let store = ModelPreferences()
    let keys = ModelKeys()
    let old = ModelProfile(name: "Old", endpoint: "https://old.example/chat/completions", model: "old")
    let json = String(decoding: try JSONEncoder().encode(old), as: UTF8.self)
    try await store.set(json, forKey: ModelSettings.preferenceKey)
    keys.values["api-key"] = "legacy-key"
    let settings = keys.settings(environment: ["POLISH_ENDPOINT": "https://env.example/chat/completions", "POLISH_MODEL": "env", "POLISH_API_KEY": "env-key"])
    await settings.attach(store)
    #expect(settings.profile == old)
    #expect(settings.apiKey == "legacy-key")
    #expect(settings.profiles.count == 1)
    #expect(keys.values["api-key"] == "legacy-key")
    #expect(await store.value(forKey: ModelSettings.preferenceKey) == json)
    let restarted = keys.settings()
    await restarted.attach(store)
    #expect(restarted.activeID == settings.activeID)
    #expect(restarted.apiKey == "legacy-key")
}

@MainActor @Test func missingLegacyKeyDoesNotBorrowEnvironmentCredential() async throws {
    let store = ModelPreferences()
    let keys = ModelKeys()
    let old = ModelProfile(endpoint: "https://old.example/chat/completions", model: "old")
    try await store.set(String(decoding: JSONEncoder().encode(old), as: UTF8.self), forKey: ModelSettings.preferenceKey)
    let settings = keys.settings(environment: ["POLISH_ENDPOINT": "https://env.example/chat/completions", "POLISH_MODEL": "env", "POLISH_API_KEY": "env-key"])
    await settings.attach(store)
    #expect(settings.profile == old)
    #expect(settings.apiKey.isEmpty)
    #expect(!settings.isConfigured)
}

@MainActor @Test func failedSaveCannotChangePreviouslySavedKeyOrActiveProfile() async throws {
    let store = ModelPreferences()
    let keys = ModelKeys()
    let settings = keys.settings()
    await settings.attach(store)
    let old = ModelProfile(endpoint: "https://old.example/chat/completions", model: "old")
    try await settings.save(old, apiKey: "old-key")
    let id = settings.activeID
    await store.failWrites()
    await #expect(throws: PolishError.invalidResponse) { try await settings.save(old, apiKey: "new-key", id: id) }
    #expect(settings.apiKey == "old-key")
    let restarted = keys.settings()
    await restarted.attach(store)
    #expect(restarted.activeID == id)
    #expect(restarted.apiKey == "old-key")
}

@MainActor @Test func providerCollectionSurvivesRealSQLiteReopenWithoutPlaintextKeys() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: directory) }
    let location = Database.Location.file(directory.appendingPathComponent("models.sqlite3"))
    let keys = ModelKeys()
    let storage = try await PolishStorage.open(location)
    let settings = keys.settings()
    await settings.attach(storage.preferences)
    let profile = ModelProfile(name: "Synthetic Custom", endpoint: "https://custom.example/chat/completions", model: "deployment-test")
    try await settings.save(profile, apiKey: "synthetic-private-key")
    let restored = keys.settings()
    let reopened = try await PolishStorage.open(location)
    await restored.attach(reopened.preferences)
    #expect(restored.activeID == settings.activeID)
    #expect(restored.profile == profile)
    #expect(restored.apiKey == "synthetic-private-key")
    let json = try #require(try await reopened.preferences.value(forKey: ModelSettings.collectionKey))
    #expect(!json.contains("synthetic-private-key"))
}
