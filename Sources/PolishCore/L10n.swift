import Foundation

/// Shared UI and error strings use Apple's localized resources. User text and prompts
/// never pass through this API. The selected bundle stays fixed for this process.
public enum L10n {
    public static let resources: Bundle = {
        if Bundle.main.bundleURL.pathExtension == "app" {
            return Bundle(url: Bundle.main.resourceURL!.appendingPathComponent("TextPolish_PolishCore.bundle"))!
        }
        return Bundle.module
    }()

    public static let language = resources.preferredLocalizations.first ?? "zh-Hans"
    public static let locale = Locale(identifier: language)
    private static let selectedBundle = bundle(for: language)

    // SwiftPM in Swift 6.3 lowercases localization resource directories (zh-hans.lproj);
    // Swift 6.4 keeps the source case (zh-Hans.lproj). Bundle lookup is case-sensitive.
    public static func bundle(for language: String) -> Bundle {
        let path = resources.path(forResource: language, ofType: "lproj")
            ?? resources.path(forResource: language.lowercased(), ofType: "lproj")
        return Bundle(path: path!)!
    }

    public static func tr(_ key: String) -> String {
        selectedBundle.localizedString(forKey: key, value: nil, table: nil)
    }

    public static func format(_ key: String, _ arguments: String...) -> String {
        String(format: tr(key), locale: locale, arguments: arguments)
    }
}
