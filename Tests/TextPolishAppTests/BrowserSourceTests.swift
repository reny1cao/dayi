import AppKit
import ApplicationServices
import PolishCore
import PolishStore
import Testing
@testable import TextPolishApp

@Suite @MainActor struct BrowserSourceTests {
    @Test func browserIdentityDoesNotTreatEveryWebHostAsABrowser() {
        for id in ["com.google.Chrome", "com.apple.Safari", "org.mozilla.firefox", "com.microsoft.edgemac", "com.brave.Browser"] {
            #expect(BrowserSource.isBrowser(bundleID: id))
        }
        for id in [nil, "com.openai.codex", "com.anthropic.claudefordesktop", "com.googlecode.iterm2", "com.github.Electron",
                   "com.google.Chrome.helper", "com.google.Chrome.attacker"] {
            #expect(!BrowserSource.isBrowser(bundleID: id))
        }
    }

    @Test func websiteLabelsDoNotReplaceTheHostAndSurviveFailedAttempts() throws {
        let website = try #require(WebsiteSource(host: "mail.google.com"))
        let history = PolishHistory()
        history.recordFailure(in: "Google Chrome", message: "合成失败", startedAt: Date(), website: website)
        let item = ActivityItem(record: try #require(history.records.first))
        #expect(item.sourceLabel == "mail.google.com")
        #expect(item.targetLabel == "Google Chrome")
        #expect(item.matches("MAIL.GOOGLE"))
        #expect(item.matches("Chrome"))
        #expect(item.rowSummary.contains("mail.google.com"))
        #expect(item.rowSummary.contains("Google Chrome"))
        let old = ActivityItem(record: PolishRecord(targetLabel: "Google Chrome", outcome: .failed))
        #expect(old.website == nil)
        #expect(old.sourceLabel == "Google Chrome")
        let cell = ActivityTextCell(frame: NSRect(x: 0, y: 0, width: 200, height: 36))
        cell.configure(item, column: .app, perform: { _ in })
        #expect(cell.textField?.stringValue == "mail.google.com")
        cell.configure(old, column: .app, perform: { _ in })
        #expect(cell.textField?.stringValue == "Google Chrome")
    }

    /// Opt-in: select synthetic text in the named browser before invoking this check.
    /// It exercises real AX capture and history projection without a model call or writeback.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DAYI_BROWSER_SOURCE_BUNDLE_ID"] != nil))
    func readsTheCapturedBrowserPage() async throws {
        let env = ProcessInfo.processInfo.environment
        let bundle = try #require(env["DAYI_BROWSER_SOURCE_BUNDLE_ID"])
        let expected = try #require(env["DAYI_BROWSER_SOURCE_EXPECTED_HOST"])
        let app = try #require(env["DAYI_BROWSER_SOURCE_PID"].flatMap(Int32.init)
            .flatMap(NSRunningApplication.init(processIdentifier:)) ?? NSWorkspace.shared.frontmostApplication)
        try #require(app.bundleIdentifier == bundle)
        let target = try await AXTextTarget.captureFocused(in: app) { _ in }
        #expect(target.website?.host == (expected == "none" ? nil : expected))
        #expect(target.label == app.localizedName)
        #expect(!target.supportsBackgroundWrite)
        let snapshot = try target.capture()
        #expect(snapshot.selectedText == "Synthetic browser source draft.")
        let record = PolishRecord(targetLabel: target.label, website: target.website,
                                  originalText: snapshot.selectedText, outcome: .waiting)
        let store = try await PolishStorage.open(.memory)
        try await store.records.save(record)
        let item = ActivityItem(record: try #require(try await store.records.record(record.id)))
        #expect(item.website == target.website)
        print("Browser source verified: \(bundle), host=\(target.website?.host ?? "none"), draft preserved")
    }
}
