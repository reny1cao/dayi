import AppKit
import Carbon
import PolishStore
import Testing
@testable import TextPolishApp

@Suite @MainActor
struct HotKeyBindingTests {
    @Test func commandXIsRecordableWithoutChangingDefaults() throws {
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0,
            windowNumber: 0, context: nil, characters: "x", charactersIgnoringModifiers: "x",
            isARepeat: false, keyCode: UInt16(kVK_ANSI_X)
        ))
        #expect(HotKeyBinding(event: event) == .systemCut)
        #expect(HotKeyBinding.polishDefault.display == "⌃⌥P")
        #expect(HotKeyBinding.undoDefault.display == "⌃⌥Z")
        #expect(HotKeyBinding(keyCode: UInt32(kVK_ANSI_X), modifiers: UInt32(cmdKey | shiftKey)) != .systemCut)
    }

    @Test func recordingCutWaitsForConfirmationAndCancelDoesNotSave() async throws {
        let preferences = try await PolishStorage.open(.memory).preferences
        let bindings = HotKeyBindings()
        await bindings.attach(preferences)

        await bindings.requestUpdate(.systemCut, for: .polish)
        #expect(bindings.pendingCutRole == .polish)
        #expect(bindings.polish == .polishDefault)
        #expect(bindings.conflict == nil)
        #expect(try await preferences.value(forKey: "hotkey.polish") == nil)

        bindings.cancelPendingUpdate()
        #expect(bindings.pendingCutRole == nil)
        #expect(bindings.polish == .polishDefault)
        #expect(try await preferences.value(forKey: "hotkey.polish") == nil)
    }

    @Test func confirmingCutStillRequiresSuccessfulRegistrationBeforeSaving() async throws {
        let preferences = try await PolishStorage.open(.memory).preferences
        let bindings = HotKeyBindings()
        await bindings.attach(preferences)
        await bindings.requestUpdate(.systemCut, for: .polish)
        let role = try #require(bindings.pendingCutRole)

        // The alert dismisses before its action runs. Its captured role remains valid,
        // but no live registrar is installed in this test: confirmation must not save.
        bindings.cancelPendingUpdate()
        await bindings.update(.systemCut, for: role)
        #expect(bindings.pendingCutRole == nil)
        #expect(bindings.polish == .polishDefault)
        #expect(bindings.conflict != nil)
        #expect(try await preferences.value(forKey: "hotkey.polish") == nil)
    }

    @Test func otherShortcutsKeepExistingConflictHandling() async throws {
        let bindings = HotKeyBindings()
        await bindings.requestUpdate(.undoDefault, for: .polish)
        #expect(bindings.pendingCutRole == nil)
        #expect(bindings.polish == .polishDefault)
        #expect(bindings.undo == .undoDefault)
        #expect(bindings.conflict != nil)
    }

    @Test func loadingSavedCustomShortcutDoesNotAskOrOverwriteIt() async throws {
        let preferences = try await PolishStorage.open(.memory).preferences
        let saved = String(decoding: try JSONEncoder().encode(HotKeyBinding.systemCut), as: UTF8.self)
        try await preferences.set(saved, forKey: "hotkey.polish")
        let bindings = HotKeyBindings()

        await bindings.attach(preferences)
        #expect(bindings.pendingCutRole == nil)
        #expect(try await preferences.value(forKey: "hotkey.polish") == saved)
        // Launch registration is deliberately absent; the model must not claim it worked.
        #expect(bindings.polish == .polishDefault)
        #expect(bindings.conflict != nil)
    }
}
