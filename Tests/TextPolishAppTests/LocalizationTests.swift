import Foundation
import PolishCore
import Testing
@testable import TextPolishApp

@Suite struct LocalizationTests {
    @Test func languagePreferencePersistsWithoutChangingOtherDefaults() throws {
        let suite = "Dayi.LocalizationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(InterfaceLanguage.load(from: defaults) == .system)
        defaults.set("keep", forKey: "unrelated")
        InterfaceLanguage.english.save(to: defaults)
        #expect(InterfaceLanguage.load(from: defaults) == .english)
        #expect(defaults.stringArray(forKey: "AppleLanguages") == ["en"])
        InterfaceLanguage.chinese.save(to: defaults)
        #expect(defaults.stringArray(forKey: "AppleLanguages") == ["zh-Hans"])
        InterfaceLanguage.system.save(to: defaults)
        #expect(defaults.persistentDomain(forName: suite)?["AppleLanguages"] == nil)
        #expect(defaults.string(forKey: "unrelated") == "keep")
    }

    @Test func englishAndChineseResourcesHaveMatchingKeysAndFormats() throws {
        let english = L10n.bundle(for: "en")
        let chinese = L10n.bundle(for: "zh-Hans")
        let enURL = try #require(english.url(forResource: "Localizable", withExtension: "strings"))
        let zhURL = try #require(chinese.url(forResource: "Localizable", withExtension: "strings"))
        let en = try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: enURL), format: nil) as? [String: String])
        let zh = try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: zhURL), format: nil) as? [String: String])
        #expect(Set(en.keys) == Set(zh.keys))
        #expect(en.count > 200)
        for key in en.keys {
            #expect(en[key]?.components(separatedBy: "%@").count == zh[key]?.components(separatedBy: "%@").count)
            #expect(en[key]?.isEmpty == false)
        }
        #expect(english.localizedString(forKey: "全部活动", value: nil, table: nil) == "All Activity")
        #expect(chinese.localizedString(forKey: "全部活动", value: nil, table: nil) == "全部活动")
        let format = english.localizedString(forKey: "已替换 %@ 的选区", value: nil, table: nil)
        #expect(String(format: format, "Notes") == "Replaced the selection in Notes")
        #expect(english.localizedString(forKey: "输入不能为空。", value: nil, table: nil) == "Input cannot be empty.")
    }

    @Test func changingPreferenceDoesNotChangeTheRunningSession() throws {
        let language = L10n.language
        let title = L10n.tr("全部活动")
        let suite = "Dayi.LocalizationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        InterfaceLanguage.english.save(to: defaults)
        #expect(L10n.language == language)
        #expect(L10n.tr("全部活动") == title)
    }
}
