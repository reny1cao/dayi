import Foundation
import PolishCore

/// AppleLanguages is stored in this application's domain only. AppKit and Foundation
/// both read it on the next launch, so changing language never half-translates a session.
enum InterfaceLanguage: String, CaseIterable, Identifiable {
    case system, chinese = "zh-Hans", english = "en"
    static let preferenceKey = "interface.language"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: L10n.tr("跟随系统")
        case .chinese: "简体中文"
        case .english: "English"
        }
    }
    static func load(from defaults: UserDefaults = .standard) -> Self {
        Self(rawValue: defaults.string(forKey: preferenceKey) ?? "") ?? .system
    }
    func save(to defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.preferenceKey)
        if self == .system {
            defaults.removeObject(forKey: "AppleLanguages")
        } else {
            defaults.set([rawValue], forKey: "AppleLanguages")
        }
    }
}
