import PolishCore
import AppKit
import SwiftUI

/// Scene identifiers, in one place because two files open the same window: the menu bar's
/// 活动窗口 row and the ⌘0 command.
enum DayiScene {
    static let activityWindow = "activity"
}

/// What the frontmost activity window lets the menu bar drive. One focused value rather than
/// four keys: the window publishes it in a single line, and every command below is disabled
/// together when no activity window is in front — which is exactly when none of them mean
/// anything.
///
/// The window publishes it with
/// `.focusedSceneValue(\.activity, ActivityFocus(store:search:inspector:clearConfirmation:))`.
struct ActivityFocus {
    let store: ActivityStore
    /// Raised by ⌘F. Bind it to `.searchable(text:isPresented:)`, which focuses the field.
    let search: Binding<Bool>
    /// Whether the inspector is showing. Bind it to `.inspector(isPresented:)`.
    let inspector: Binding<Bool>
    /// Whether the 清空历史 confirmation is up. A sheet belongs to a view, not to a menu.
    let clearConfirmation: Binding<Bool>
    /// True while the keyboard is inside the window's search field. A menu key equivalent is
    /// matched before the event reaches the responder chain, so the two commands below that
    /// use a bare key — ⌫ and ↩ — disable themselves while someone is typing. Without this a
    /// backspace in the search box would delete the selected records.
    let isEditingText: Bool
}

struct ActivityFocusKey: FocusedValueKey {
    typealias Value = ActivityFocus
}

extension FocusedValues {
    var activity: ActivityFocus? {
        get { self[ActivityFocusKey.self] }
        set { self[ActivityFocusKey.self] = newValue }
    }
}

/// Every command this product has, in the menu bar, each with the keystroke §9 assigns it.
/// There is no command palette: eight commands do not need one, and the menu bar is the
/// native answer at this scale.
///
/// `⌘Z` is deliberately never bound to 撤回最近一次. In the activity window `⌘Z` should undo a
/// record deletion; the polish undo is `⌃⌥Z` and happens in the other application.
struct AppCommands: Commands {
    @FocusedValue(\.activity) private var activity: ActivityFocus?
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        // No 设置… item here. The `Settings` scene contributes its own, already bound to ⌘,,
        // and `CommandGroup(replacing: .appSettings)` does not displace it on macOS 26 — the
        // two coexist and the menu grows a duplicate. The bundle carries a zh-Hans
        // localization so AppKit titles that one 设置… rather than "Settings…".
        CommandGroup(after: .appInfo) {
            if UpdateController.isAvailable {
                Button(L10n.tr("检查更新…")) { UpdateController.shared.checkForUpdates() }
            }
            Divider()
            // Carbon hot keys, not menu commands: a menu item can only be chosen while Dayi
            // is frontmost, which is the one moment neither of these can do anything. They
            // are named here so the menu bar still teaches the two gestures that exist, and
            // the combination is read off the live registration because both are rebindable.
            ForEach(HotKeyBindings.Role.allCases) { role in
                Text("\(role.title) · \(HotKeyBindings.shared.binding(for: role).display)")
            }
        }

        CommandGroup(before: .windowList) {
            Button(L10n.tr("活动窗口")) {
                openWindow(id: DayiScene.activityWindow)
                NSApp.activate()
            }
            .keyboardShortcut("0", modifiers: .command)
            Divider()
        }

        CommandGroup(after: .pasteboard) {
            Divider()
            // ↩ on a waiting row. R1 in one keystroke, so it sits with the other record
            // commands rather than behind a pointer gesture.
            Button(jumpTitle) {
                guard let item = jumpTarget else { return }
                activity?.store.jumpBack(item)
            }
            .keyboardShortcut(.return, modifiers: [])
            .disabled(jumpTarget == nil || activity?.isEditingText == true)

            // The one ⌘C the design system's shortcut table lists, and the only entry that
            // answers it: the table no longer declares `.copyable`, so the system's 拷贝 stays
            // disabled while the table has focus and this item takes the key.
            Button(L10n.tr("复制润色结果")) {
                guard let item = copyTarget else { return }
                activity?.store.copyResult(item)
            }
            .keyboardShortcut("c", modifiers: .command)
            // ⌘C in the search field means the text in the search field, where the system's
            // own 拷贝 is enabled and has to win.
            .disabled(copyTarget == nil || activity?.isEditingText == true)

            Button(L10n.tr("搜索记录")) { activity?.search.wrappedValue = true }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(activity == nil)

            Divider()

            Button(L10n.tr("删除选中记录")) {
                guard let store = activity?.store else { return }
                store.delete(store.selection)
            }
            .keyboardShortcut(.delete, modifiers: [])
            .disabled(activity?.store.selection.isEmpty != false || activity?.isEditingText == true)

            Button(L10n.tr("清空历史…")) { activity?.clearConfirmation.wrappedValue = true }
                .keyboardShortcut(.delete, modifiers: [.shift, .command])
                .disabled(activity?.store.isEmpty != false)
        }

        // Replacing rather than extending: SwiftUI installs its own sidebar item here, and two
        // items answering ⌃⌥⌘S would be one too many.
        CommandGroup(replacing: .sidebar) {
            Button(L10n.tr("显示/隐藏边栏")) {
                NSApp.sendAction(#selector(NSSplitViewController.toggleSidebar(_:)), to: nil, from: nil)
            }
            .keyboardShortcut("s", modifiers: [.control, .command])
            .disabled(activity == nil)

            Button(activity?.inspector.wrappedValue == true ? L10n.tr("隐藏检查器") : L10n.tr("显示检查器")) {
                activity?.inspector.wrappedValue.toggle()
            }
            .keyboardShortcut("i", modifiers: [.option, .command])
            .disabled(activity == nil)

            Divider()
            filter(L10n.tr("待应用"), .pending, "1")
            filter(L10n.tr("未完成"), .unfinished, "2")
            filter(L10n.tr("全部活动"), .all, "3")
        }
    }

    /// The three inbox filters are a radio group: turning one off says nothing, so only
    /// turning one on does anything. A check mark beside the live one is what a menu is for.
    private func filter(_ title: String, _ value: ActivityStore.Filter, _ key: KeyEquivalent) -> some View {
        Toggle(title, isOn: Binding(
            get: { activity?.store.filter == value },
            set: { if $0 { activity?.store.filter = value } }
        ))
        .keyboardShortcut(key, modifiers: .command)
        .disabled(activity == nil)
    }

    /// Only a waiting result whose context is still in memory can be jumped back to; a row
    /// read off disk names an accessibility element that died with its process.
    private var jumpTarget: ActivityItem? {
        guard let item = activity?.store.selected, item.state == .blocked, item.isLive else { return nil }
        return item
    }

    private var jumpTitle: String {
        jumpTarget.map { ActivityAction.jumpBack.title(for: $0) } ?? L10n.tr("跳回原应用")
    }

    private var copyTarget: ActivityItem? {
        guard let item = activity?.store.selected, item.hasResult else { return nil }
        return item
    }
}
