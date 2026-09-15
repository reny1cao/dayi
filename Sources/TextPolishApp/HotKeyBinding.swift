import PolishCore
import AppKit
import Carbon
import Observation
import PolishStore
import SwiftUI

/// One combination, as Carbon needs it and as a person reads it.
///
/// The key is stored as a virtual key code rather than a character because the same physical
/// key has to keep working under a Pinyin or Dvorak layout — which is the whole point of a
/// shortcut that fires inside somebody else's application.
struct HotKeyBinding: Codable, Equatable, Hashable, Sendable {
    var keyCode: UInt32
    /// A Carbon modifier mask (`controlKey | optionKey`), not an `NSEvent.ModifierFlags`.
    var modifiers: UInt32

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// The two defaults are the product. Every failure path below returns to them.
    static let polishDefault = HotKeyBinding(keyCode: UInt32(kVK_ANSI_P), modifiers: UInt32(controlKey | optionKey))
    static let undoDefault = HotKeyBinding(keyCode: UInt32(kVK_ANSI_Z), modifiers: UInt32(controlKey | optionKey))
    static let systemCut = HotKeyBinding(keyCode: UInt32(kVK_ANSI_X), modifiers: UInt32(cmdKey))

    /// A recorded press. A bare key — or shift and a key — is refused: it would swallow
    /// typing in every other application, and this hot key is global.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var mask: UInt32 = 0
        if flags.contains(.control) { mask |= UInt32(controlKey) }
        if flags.contains(.option) { mask |= UInt32(optionKey) }
        if flags.contains(.shift) { mask |= UInt32(shiftKey) }
        if flags.contains(.command) { mask |= UInt32(cmdKey) }
        guard mask != 0, mask != UInt32(shiftKey) else { return nil }
        guard Self.names[UInt32(event.keyCode)] != nil else { return nil }
        self.init(keyCode: UInt32(event.keyCode), modifiers: mask)
    }

    /// "⌃⌥P", in the order macOS prints modifiers.
    var display: String {
        var text = ""
        if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + (Self.names[keyCode] ?? L10n.format("键 %@", String(describing: keyCode)))
    }

    /// Key codes this recorder is willing to name. A code with no name is refused rather
    /// than shown as a number a person cannot map back to a key.
    private static let names: [UInt32: String] = {
        let keys: [(Int, String)] = [
            (kVK_ANSI_A, "A"), (kVK_ANSI_B, "B"), (kVK_ANSI_C, "C"), (kVK_ANSI_D, "D"), (kVK_ANSI_E, "E"),
            (kVK_ANSI_F, "F"), (kVK_ANSI_G, "G"), (kVK_ANSI_H, "H"), (kVK_ANSI_I, "I"), (kVK_ANSI_J, "J"),
            (kVK_ANSI_K, "K"), (kVK_ANSI_L, "L"), (kVK_ANSI_M, "M"), (kVK_ANSI_N, "N"), (kVK_ANSI_O, "O"),
            (kVK_ANSI_P, "P"), (kVK_ANSI_Q, "Q"), (kVK_ANSI_R, "R"), (kVK_ANSI_S, "S"), (kVK_ANSI_T, "T"),
            (kVK_ANSI_U, "U"), (kVK_ANSI_V, "V"), (kVK_ANSI_W, "W"), (kVK_ANSI_X, "X"), (kVK_ANSI_Y, "Y"),
            (kVK_ANSI_Z, "Z"),
            (kVK_ANSI_0, "0"), (kVK_ANSI_1, "1"), (kVK_ANSI_2, "2"), (kVK_ANSI_3, "3"), (kVK_ANSI_4, "4"),
            (kVK_ANSI_5, "5"), (kVK_ANSI_6, "6"), (kVK_ANSI_7, "7"), (kVK_ANSI_8, "8"), (kVK_ANSI_9, "9"),
            (kVK_ANSI_Minus, "-"), (kVK_ANSI_Equal, "="), (kVK_ANSI_LeftBracket, "["), (kVK_ANSI_RightBracket, "]"),
            (kVK_ANSI_Backslash, "\\"), (kVK_ANSI_Semicolon, ";"), (kVK_ANSI_Quote, "'"), (kVK_ANSI_Comma, ","),
            (kVK_ANSI_Period, "."), (kVK_ANSI_Slash, "/"), (kVK_ANSI_Grave, "`"),
            (kVK_Space, "␣"), (kVK_Return, "↩"), (kVK_Tab, "⇥"), (kVK_ForwardDelete, "⌦"),
            (kVK_LeftArrow, "←"), (kVK_RightArrow, "→"), (kVK_UpArrow, "↑"), (kVK_DownArrow, "↓"),
            (kVK_Home, "↖"), (kVK_End, "↘"), (kVK_PageUp, "⇞"), (kVK_PageDown, "⇟"),
            (kVK_F1, "F1"), (kVK_F2, "F2"), (kVK_F3, "F3"), (kVK_F4, "F4"), (kVK_F5, "F5"), (kVK_F6, "F6"),
            (kVK_F7, "F7"), (kVK_F8, "F8"), (kVK_F9, "F9"), (kVK_F10, "F10"), (kVK_F11, "F11"), (kVK_F12, "F12"),
        ]
        return Dictionary(uniqueKeysWithValues: keys.map { (UInt32($0.0), $0.1) })
    }()
}

/// The two global combinations, and the only place that decides what is registered.
///
/// `AppModel` builds the `GlobalHotKey` before the database is open, so registration always
/// starts from the defaults and a saved binding is applied when preferences arrive. Anything
/// that will not register falls back to the combination that was working a moment ago: this
/// product is two keystrokes, and leaving none of them registered is worse than refusing a
/// change.
@MainActor @Observable
final class HotKeyBindings {
    enum Role: String, CaseIterable, Identifiable, Sendable {
        case polish, undo

        var id: String { rawValue }
        /// The Carbon hot key id `AppModel` switches on: 1 polishes, 2 undoes.
        var hotKeyID: UInt32 { self == .polish ? 1 : 2 }
        var preferenceKey: String { "hotkey.\(rawValue)" }
        var title: String { self == .polish ? L10n.tr("润色选区") : L10n.tr("撤回最近一次") }
        /// The line beside the recorder on the canvas.
        var note: String { self == .polish ? L10n.tr("全局，覆盖其他应用") : L10n.tr("不占用 ⌘Z") }
        var fallback: HotKeyBinding { self == .polish ? .polishDefault : .undoDefault }
    }

    static let shared = HotKeyBindings()

    private(set) var polish = HotKeyBinding.polishDefault
    private(set) var undo = HotKeyBinding.undoDefault
    /// Why the last attempt did not take. `GlobalHotKey` has always known this; until now it
    /// only reached the user as one orange sentence in the window.
    private(set) var conflict: String?
    /// Only a newly recorded standard Cut shortcut needs an explicit choice. Loading a
    /// previously saved binding does not ask again or rewrite the user's preference.
    private(set) var pendingCutRole: Role?

    @ObservationIgnored private weak var hotKey: GlobalHotKey?
    @ObservationIgnored private var preferences: (any PreferenceStore)?

    func binding(for role: Role) -> HotKeyBinding {
        switch role {
        case .polish: polish
        case .undo: undo
        }
    }

    /// What `GlobalHotKey` registers, keyed by the id the handler reports back.
    var assignments: [UInt32: HotKeyBinding] {
        [Role.polish.hotKeyID: polish, Role.undo.hotKeyID: undo]
    }

    /// The live hot key registers itself here so a rebind reaches the same instance rather
    /// than a second set of Carbon registrations.
    func adopt(_ hotKey: GlobalHotKey) { self.hotKey = hotKey }

    /// Integration hook: one line in `AppModel.openStorage()`, next to `settings.attach`.
    func attach(_ store: any PreferenceStore) async {
        preferences = store
        var loaded: [Role: HotKeyBinding] = [:]
        for role in Role.allCases {
            guard let json = try? await store.value(forKey: role.preferenceKey),
                  let saved = try? JSONDecoder().decode(HotKeyBinding.self, from: Data(json.utf8)) else { continue }
            loaded[role] = saved
        }
        guard !loaded.isEmpty else { return }
        let previous = (polish: polish, undo: undo)
        if let saved = loaded[.polish] { polish = saved }
        if let saved = loaded[.undo] { undo = saved }
        // Optional chaining would evaluate to nil here rather than throwing, so a launch whose
        // registration failed outright would silently adopt the saved combination and show it
        // as the live one. Nothing is registered, so nothing is claimed.
        guard let hotKey else {
            polish = previous.polish
            undo = previous.undo
            conflict = L10n.tr("快捷键当前没有注册，保存的组合要等下次启动才会生效。")
            return
        }
        do {
            try hotKey.apply(assignments)
            conflict = nil
        } catch {
            polish = previous.polish
            undo = previous.undo
            try? hotKey.apply(assignments)
            conflict = L10n.format("保存的快捷键没能注册，已回到 %@ / %@。", String(describing: polish.display), String(describing: undo.display))
        }
    }

    func requestUpdate(_ binding: HotKeyBinding, for role: Role) async {
        if binding == .systemCut, binding != self.binding(for: role) {
            pendingCutRole = role
            return
        }
        await update(binding, for: role)
    }

    func cancelPendingUpdate() { pendingCutRole = nil }

    /// Registers the combination first and persists only what registered. A stored binding
    /// that cannot be registered would come back broken on every launch.
    func update(_ binding: HotKeyBinding, for role: Role) async {
        pendingCutRole = nil
        let previous = self.binding(for: role)
        guard binding != previous else {
            conflict = nil
            return
        }
        if let other = Role.allCases.first(where: { $0 != role && self.binding(for: $0) == binding }) {
            conflict = L10n.format("%@ 已经是「%@」的快捷键。", String(describing: binding.display), String(describing: other.title))
            return
        }
        // Same hole as `attach`: `try hotKey?.apply(...)` on a nil hot key evaluates to nil
        // instead of throwing, which would clear the conflict, persist the combination and
        // let the recorder display a shortcut that is registered nowhere.
        guard let hotKey else {
            conflict = L10n.tr("快捷键当前没有注册，改动要等下次启动才会生效。")
            return
        }
        set(binding, for: role)
        do {
            try hotKey.apply(assignments)
            conflict = nil
            await persist(role)
        } catch {
            set(previous, for: role)
            try? hotKey.apply(assignments)
            conflict = L10n.format("%@ 未能注册，多半已被其他应用占用；仍然是 %@。", String(describing: binding.display), String(describing: previous.display))
        }
    }

    func reset(_ role: Role) async { await update(role.fallback, for: role) }

    private func set(_ binding: HotKeyBinding, for role: Role) {
        switch role {
        case .polish: polish = binding
        case .undo: undo = binding
        }
    }

    private func persist(_ role: Role) async {
        guard let preferences, let data = try? JSONEncoder().encode(binding(for: role)) else { return }
        do {
            try await preferences.set(String(decoding: data, as: UTF8.self), forKey: role.preferenceKey)
        } catch {
            conflict = L10n.format("快捷键已生效，但没能写进设置：下次启动会回到 %@。", String(describing: role.fallback.display))
        }
    }
}

/// The 78×22 field on the 通用 canvas. Click it, press the next combination, and the change
/// is registered before it is written down — so the conflict warning beside it describes a
/// registration that actually happened.
struct HotKeyRecorder: View {
    let role: HotKeyBindings.Role
    var bindings: HotKeyBindings = .shared

    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            if recording { stop() } else { start() }
        } label: {
            Text(recording ? L10n.tr("按下…") : bindings.binding(for: role).display)
                .font(.body)
                .foregroundStyle(recording ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .frame(width: SettingsMetric.recorderWidth, height: SettingsMetric.recorderHeight)
                .background(
                    RoundedRectangle(cornerRadius: Metric.radiusButton)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Metric.radiusButton)
                        .strokeBorder(recording ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color(nsColor: .separatorColor)))
                )
                .contentShape(RoundedRectangle(cornerRadius: Metric.radiusButton))
        }
        .buttonStyle(.plain)
        .help(L10n.format("点按后按下新的组合键；⎋ 取消，⌫ 恢复默认 %@", String(describing: role.fallback.display)))
        .accessibilityLabel(L10n.format("%@快捷键 %@", String(describing: role.title), String(describing: bindings.binding(for: role).display)))
        .alert(L10n.tr("将 ⌘X 用作全局快捷键？"), isPresented: Binding(
            get: { bindings.pendingCutRole == role },
            set: { if !$0 { bindings.cancelPendingUpdate() } }
        ), presenting: bindings.pendingCutRole) { pendingRole in
            Button(L10n.tr("取消"), role: .cancel) { bindings.cancelPendingUpdate() }
            Button(L10n.tr("使用 ⌘X")) {
                Task { await bindings.update(.systemCut, for: pendingRole) }
            }
        } message: { pendingRole in
            Text(L10n.format("⌘X 通常用于剪切。启用后，Dayi 会在其他应用中占用这个组合，普通剪切可能无法使用。仍要将它设为「%@」吗？", String(describing: pendingRole.title)))
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        recording = true
        // A local monitor swallows the press so recording ⌘W does not close the window on
        // the way to being recorded.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            MainActor.assumeIsolated { handle(event) }
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func handle(_ event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) {
            stop()
            return
        }
        if event.keyCode == UInt16(kVK_Delete) {
            stop()
            Task { await bindings.reset(role) }
            return
        }
        guard let binding = HotKeyBinding(event: event) else { return }
        stop()
        Task { await bindings.requestUpdate(binding, for: role) }
    }
}
