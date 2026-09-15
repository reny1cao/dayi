import AppKit
import ApplicationServices
import PolishCore
import PolishStore
import Testing
@testable import TextPolishApp

@Suite @MainActor
struct FocusReadTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DAYI_FOCUS_READ_BUNDLE_ID"] != nil))
    func readsTheCurrentHostInputWithoutEditing() async throws {
        let bundle = try #require(ProcessInfo.processInfo.environment["DAYI_FOCUS_READ_BUNDLE_ID"])
        let application = try #require(NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first)
        let target = try await AXTextTarget.captureFocused(in: application) { _ in }
        #expect(target.role == kAXTextAreaRole || target.role == kAXTextFieldRole)
        #expect(target.capturedRange == nil)
        print("Read-only host check: \(target.label), \(target.role), backgroundWrite=\(target.supportsBackgroundWrite)")
    }

    @Test func missingFocusAndFailedAXReadAreDifferent() throws {
        #expect(try AXTextTarget.checkedFocusedElement(nil, status: .noValue) == nil)
        for status in [AXError.cannotComplete, .apiDisabled, .failure] {
            #expect(throws: FocusReadError(code: status.rawValue)) {
                try AXTextTarget.checkedFocusedElement(nil, status: status)
            }
        }
        #expect(throws: TargetError.unavailable) {
            try AXTextTarget.checkedFocusedElement("invalid" as CFString, status: .success)
        }
        let element = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        let read = try #require(try AXTextTarget.checkedFocusedElement(element, status: .success))
        #expect(CFEqual(read, element))
    }

    @Test func feedbackDoesNotCallAnUnsupportedControlMissingFocus() {
        let missing = StatusEvent.failure(TargetError.noFocusedInput, app: "Notes")
        let unsupported = StatusEvent.failure(TargetError.unsupportedInput, app: "Notes")
        let failed = StatusEvent.failure(FocusReadError(code: AXError.cannotComplete.rawValue), app: "Notes")
        #expect(missing.text == L10n.format("%@ 里没有找到输入焦点 · 点进输入框再按", "Notes"))
        #expect(unsupported.text == L10n.format("%@ 的焦点不在可润色的文字输入区", "Notes"))
        #expect(failed.text != missing.text)
        #expect(failed.text.contains(String(AXError.cannotComplete.rawValue)))
    }

    @Test func aFailureBeforeJobCreationIsVisibleAndSurvivesReload() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let location = Database.Location.file(directory.appendingPathComponent("dayi.sqlite3"))
        let store = try await PolishStorage.open(location).records
        let history = PolishHistory()
        let start = Date(timeIntervalSince1970: 1_789_000_000)
        let event = StatusEvent.failure(TargetError.noFocusedInput, app: "Notes")
        history.recordFailure(in: "Notes", message: event.text, startedAt: start)
        let item = ActivityItem(record: try #require(history.records.first))
        #expect(item.state == .failed)
        #expect(item.originalText == nil)
        #expect(item.resultText == nil)
        #expect(item.model == nil)
        #expect(item.previewText == L10n.tr("无可用正文"))
        #expect(item.sentence == event.text)

        await history.attach(store, purging: .unlimited)
        await history.settle()
        let restored = PolishHistory()
        await restored.attach(try await PolishStorage.open(location).records, purging: .unlimited)
        #expect(restored.records.count == 1)
        #expect(restored.records.first?.createdAt == start)
        #expect(restored.records.first?.message == event.text)
        #expect(restored.records.first?.targetLabel == "Notes")
        #expect(restored.records.first?.outcome == .failed)
    }
}
