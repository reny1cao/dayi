import Foundation
import Observation
import PolishCore
import PolishStore
import Security

/// The model the next press will use, and where that choice came from. The profile is kept
/// in the preferences table; the key is kept in the keychain and never written next to it.
@MainActor @Observable
final class ModelSettings {
    enum Source: Equatable { case none, environment, saved }

    struct SavedProfile: Codable, Equatable, Identifiable {
        let id: UUID
        var profile: ModelProfile
        // A new key version is written before preferences: failed persistence cannot replace
        // the key used by a previously saved configuration.
        let keyAccount: String
    }
    struct Collection: Codable { var profiles: [SavedProfile]; var activeID: UUID }
    private(set) var profiles: [SavedProfile] = []
    private(set) var activeID: UUID?
    private(set) var persistenceError: String?
    @ObservationIgnored private var readKey: (String) -> String?
    @ObservationIgnored private var deleteKey: (String) -> Void
    @ObservationIgnored private var writeKey: (String, String) throws -> Void
    private(set) var profile: ModelProfile
    private(set) var apiKey: String
    private(set) var source: Source
    @ObservationIgnored private var preferences: (any PreferenceStore)?

    static let preferenceKey = "model.profile"
    static let collectionKey = "model.profiles"
    static let keychainService = "dev.local.dayi.model"

    init(environment: [String: String] = ProcessInfo.processInfo.environment,
         readKey: @escaping (String) -> String? = { Keychain.read(service: ModelSettings.keychainService, account: $0) },
         writeKey: @escaping (String, String) throws -> Void = { try Keychain.write($1, service: ModelSettings.keychainService, account: $0) },
         deleteKey: @escaping (String) -> Void = { Keychain.delete(service: ModelSettings.keychainService, account: $0) }) {
        self.readKey = readKey
        self.writeKey = writeKey
        self.deleteKey = deleteKey
        if let fromEnvironment = ModelProfile.environment(environment) {
            profile = fromEnvironment
            apiKey = environment["POLISH_API_KEY"] ?? ""
            source = .environment
        } else {
            profile = ModelProfile()
            apiKey = ""
            source = .none
        }
    }

    var isConfigured: Bool { (try? configuration()) != nil }

    func configuration() throws -> ModelConfiguration { try profile.configuration(apiKey: apiKey) }

    /// A saved profile wins over launch flags: it is the later, explicit choice.
    func attach(_ store: any PreferenceStore) async {
        preferences = store
        do {
            if let json = try await store.value(forKey: Self.collectionKey) {
                let collection = try JSONDecoder().decode(Collection.self, from: Data(json.utf8))
                guard Set(collection.profiles.map(\.id)).count == collection.profiles.count,
                      let active = collection.profiles.first(where: { $0.id == collection.activeID }) else {
                    throw PolishError.invalidConfiguration("已保存的模型配置无效")
                }
                profiles = collection.profiles
                activeID = active.id
                profile = active.profile
                apiKey = readKey(active.keyAccount) ?? ""
                source = .saved
            } else if let json = try await store.value(forKey: Self.preferenceKey) {
                let saved = try JSONDecoder().decode(ModelProfile.self, from: Data(json.utf8))
                // Never pair a saved endpoint with a launch environment's key.
                let key = readKey("api-key") ?? ""
                profile = saved
                apiKey = key
                source = .saved
                let entry = SavedProfile(id: UUID(), profile: saved, keyAccount: "profile-" + UUID().uuidString)
                if !key.isEmpty { try writeKey(entry.keyAccount, key) }
                try await persist([entry], activeID: entry.id)
                profiles = [entry]
                activeID = entry.id
                profile = saved
                apiKey = key
                source = .saved
            }
            persistenceError = nil
        } catch {
            persistenceError = error.localizedDescription
        }
    }

    func key(for saved: SavedProfile) -> String { readKey(saved.keyAccount) ?? "" }

    /// Saving activates the edited configuration. Selecting an entry in the editor alone
    /// cannot change what the next global hotkey uses.
    func save(_ candidate: ModelProfile, apiKey key: String, id: UUID? = nil) async throws {
        _ = try candidate.configuration(apiKey: key)
        let previous = profiles.first { $0.id == id }
        let account = previous.flatMap { readKey($0.keyAccount) == key ? $0.keyAccount : nil }
            ?? "profile-" + UUID().uuidString
        let entry = SavedProfile(id: id ?? UUID(), profile: candidate, keyAccount: account)
        guard preferences != nil else { throw PolishError.invalidConfiguration("历史数据库尚未打开，稍后再保存") }
        if previous?.keyAccount != account { try writeKey(entry.keyAccount, key) }
        var updated = profiles
        if let index = updated.firstIndex(where: { $0.id == entry.id }) { updated[index] = entry }
        else { updated.append(entry) }
        do { try await persist(updated, activeID: entry.id) }
        catch {
            if previous?.keyAccount != account { deleteKey(account) }
            throw error
        }
        if let previous, previous.keyAccount != account { deleteKey(previous.keyAccount) }
        profiles = updated
        activeID = entry.id
        profile = candidate
        apiKey = key
        source = .saved
        persistenceError = nil
    }

    private func persist(_ profiles: [SavedProfile], activeID: UUID) async throws {
        guard let preferences else { throw PolishError.invalidConfiguration("历史数据库尚未打开，稍后再保存") }
        let json = String(decoding: try JSONEncoder().encode(Collection(profiles: profiles, activeID: activeID)), as: UTF8.self)
        try await preferences.set(json, forKey: Self.collectionKey)
    }

    /// One real request with the unsaved candidate, so a wrong key or a rejected parameter
    /// shows up here rather than on the next press.
    nonisolated func probe(_ candidate: ModelProfile, apiKey key: String) async throws -> (Completion, Duration) {
        let polisher = try Polisher(configuration: candidate.configuration(apiKey: key), template: .bundled())
        let clock = ContinuousClock()
        let start = clock.now
        let completion = try await polisher.complete("把这个按钮改成红色，点了以后弹个确认框")
        return (completion, clock.now - start)
    }
}

/// Generic-password items in the login keychain, scoped to this app's service name.
enum Keychain {
    static func read(service: String, account: String) -> String? {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
                                      kSecAttrAccount: account, kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(service: String, account: String) {
        SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service,
                       kSecAttrAccount: account] as CFDictionary)
    }

    static func write(_ value: String, service: String, account: String) throws {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
        let attributes: [CFString: Any] = [kSecValueData: Data(value.utf8)]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { $1 } as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw PolishError.invalidConfiguration(L10n.format("钥匙串写入失败（%@）", String(describing: status)))
        }
    }
}
