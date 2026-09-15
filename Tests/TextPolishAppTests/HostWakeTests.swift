import AppKit
import ApplicationServices
import PolishCore
import Testing
@testable import TextPolishApp

/// A live check against a real Chromium host, run by hand: it needs a trusted process, the
/// host's pid in `DAYI_HOST_WAKE_PID`, and it takes that host to the foreground for a few
/// seconds. It turns the host's tree off first, so it exercises the wake path itself rather
/// than a tree some other client already woke.
@MainActor
struct HostWakeTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DAYI_HOST_WAKE_PID"] != nil))
    func wakesASleepingChromiumHost() async throws {
        let pid = try #require(ProcessInfo.processInfo.environment["DAYI_HOST_WAKE_PID"].flatMap { pid_t($0) })
        let host = try #require(NSRunningApplication(processIdentifier: pid))
        try #require(AXIsProcessTrusted(), "the test process is not trusted for accessibility")
        let previous = NSWorkspace.shared.frontmostApplication
        defer { previous?.activate() }
        host.activate()
        try await Task.sleep(for: .seconds(1))
        try #require(NSWorkspace.shared.frontmostApplication?.processIdentifier == pid, "host did not come to the front")

        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 1)
        AXUIElementSetAttributeValue(appElement, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse)
        try await Task.sleep(for: .milliseconds(300))
        var focused: CFTypeRef?
        let before = AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focused)
        print("host \(host.localizedName ?? "?") focus query before wake: \(before.rawValue) (noValue is \(AXError.noValue.rawValue))")

        var wokeHost: String?
        let clock = ContinuousClock()
        let start = clock.now
        var outcome = "captured"
        do {
            let target = try await AXTextTarget.captureFocused { wokeHost = $0 }
            outcome = "captured \(target.label)"
        } catch {
            outcome = "threw \(error)"
        }
        let elapsed = clock.now - start
        let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        print("wake callback: \(wokeHost ?? "not called"); outcome: \(outcome); elapsed: \(elapsed); frontmost after: \(front)")
        #expect(wokeHost != nil, "a sleeping host must be announced to the caller")
        #expect(outcome != "threw \(TargetError.noFocusedInput)", "host never answered with a focused element")
    }

    /// Captures whatever input the host has focused, widening a collapsed selection the way a
    /// press does. Nothing is written; the printed outcome is the evidence.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DAYI_HOST_WAKE_PID"] != nil))
    func capturesTheFocusedInputWithoutASelection() async throws {
        let pid = try #require(ProcessInfo.processInfo.environment["DAYI_HOST_WAKE_PID"].flatMap { pid_t($0) })
        let host = try #require(NSRunningApplication(processIdentifier: pid))
        let previous = NSWorkspace.shared.frontmostApplication
        defer { previous?.activate() }
        host.activate()
        try await Task.sleep(for: .seconds(1))
        do {
            let target = try await AXTextTarget.captureFocused { _ in }
            let document = try target.readDocument()
            print("focused input in \(target.label): value \((document as NSString).length) UTF-16 units")
            let snapshot = try target.capture()
            print("captured range \(snapshot.range): \(snapshot.selectedText.prefix(80).debugDescription)")
        } catch {
            print("capture outcome: \(error) — \(error.localizedDescription)")
        }
    }
}
