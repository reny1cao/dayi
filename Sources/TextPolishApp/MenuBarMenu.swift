import AppKit
import PolishCore
import SwiftUI

/// The menu bar and the HUD are this product's daily interface; the window is opened a few
/// times a year. So the waiting results are not a sentence that reports — they are rows that
/// act. One click activates the target application and puts the caret back on the selection,
/// which is the whole of R1 in a single gesture.
///
/// Rendered as `MenuBarExtra { MenuBarMenu(model:) }.menuBarExtraStyle(.window)`: the title
/// block stacks two lines around a provider logo, and every waiting result carries a second
/// line of preview text. An `NSMenuItem` can hold neither.
struct MenuBarMenu: View {
    let model: AppModel
    var bindings: HotKeyBindings = .shared

    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(\.dismiss) private var dismiss

    /// Decoded once. The menu is rebuilt on every job state change and the catalogue is 42
    /// entries of JSON.
    private static let catalog = try? ProviderCatalog.bundled()

    /// How many waiting results are worth listing before the window is the better answer.
    private static let inboxLimit = 3

    var body: some View {
        let waiting = waitingResults
        VStack(alignment: .leading, spacing: 0) {
            title(waiting.count)
            ForEach(preconditions) { issue in
                MenuBarRow(symbol: "exclamationmark.triangle.fill", tint: .orange, title: issue.title,
                           lineLimit: 2, action: issue.act)
            }
            separator
            if !waiting.isEmpty {
                ForEach(waiting.prefix(Self.inboxLimit)) { item in
                    // The inbox is the one place in this product an action wears the accent
                    // colour, and it wears it at rest: 待应用 stopped being a line of dead text
                    // and became a row you press. Capped at three, so it stays one region.
                    MenuBarRow(symbol: ActivityState.blocked.symbol, tint: ActivityState.blocked.tint,
                               title: L10n.format("切到 %@ 并应用", String(describing: item.targetLabel)), emphasized: true) {
                        model.activity.jumpBack(item)
                        dismiss()
                    }
                    preview(item)
                }
                if waiting.count > Self.inboxLimit {
                    MenuBarRow(title: L10n.format("还有 %@ 条，在活动窗口里看", String(describing: waiting.count - Self.inboxLimit)), action: openActivity)
                }
                separator
            }
            if let event = model.lastEvent {
                recent(event)
                separator
            }
            // These are Carbon hot keys that fire inside someone else's application. They are
            // named here, not offered: a menu item can only be picked while Dayi is frontmost,
            // which is the one moment neither of them can work. Both are rebindable, so the
            // combination is read off the live registration rather than spelled out.
            ForEach(HotKeyBindings.Role.allCases) { role in
                hint(role.title, bindings.binding(for: role).display)
            }
            separator
            MenuBarRow(title: L10n.tr("活动窗口"), shortcut: "⌘0", action: openActivity)
            MenuBarRow(title: L10n.tr("设置…"), shortcut: "⌘,") {
                openSettings()
                dismiss()
            }
            if UpdateController.isAvailable {
                MenuBarRow(title: L10n.tr("检查更新…")) {
                    UpdateController.shared.checkForUpdates()
                    dismiss()
                }
            }
            MenuBarRow(title: L10n.tr("退出达意"), shortcut: "⌘Q") { NSApp.terminate(nil) }
        }
        .font(.body)
        .padding(.vertical, Metric.gap4)
        .frame(width: Metric.menuWidth)
    }

    // MARK: - Blocks

    private func title(_ pending: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(headline(pending)).font(.body.weight(.semibold))
            HStack(spacing: Metric.gap4) {
                logo
                Text(modelText)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, Metric.gap12)
        .padding(.vertical, Metric.gap4)
        .accessibilityElement(children: .combine)
    }

    /// The original text of a waiting result, so a person with two of them can tell which is
    /// which without opening the window.
    private func preview(_ item: ActivityItem) -> some View {
        Text(item.previewText)
            .font(.caption)
            .foregroundStyle(.tertiary)
            .italic(item.textCleared)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, Metric.gap12)
            .padding(.bottom, Metric.gap4)
    }

    private func recent(_ event: StatusEvent) -> some View {
        Text(recentText(event))
            .font(.caption)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .padding(.horizontal, Metric.gap12)
            .padding(.vertical, Metric.gap4)
    }

    private func hint(_ title: String, _ shortcut: String) -> some View {
        HStack(spacing: Metric.gap8) {
            Text(title)
            Spacer(minLength: Metric.gap12)
            Text(shortcut).foregroundStyle(.secondary)
        }
        .padding(.horizontal, Metric.gap12)
        .padding(.vertical, Metric.gap4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.format("%@，全局快捷键 %@", String(describing: title), String(describing: shortcut)))
    }

    private var separator: some View {
        Divider().padding(.vertical, Metric.gap4)
    }

    @ViewBuilder private var logo: some View {
        if let catalog = Self.catalog, let preset = catalog.preset(matching: model.settings.profile) {
            ProviderIcon.image(for: preset, in: catalog, size: 12)
        } else {
            Image(systemName: "cloud").imageScale(.small)
        }
    }

    // MARK: - Copy

    /// 待应用 outranks every other resident state: it is the only one that expires.
    private func headline(_ pending: Int) -> String {
        pending > 0 ? L10n.format("达意 · 待应用 %@", String(describing: pending)) : L10n.format("达意 · %@", String(describing: model.status.label))
    }

    /// The model id, not the provider's name: the logo beside it already carries the brand,
    /// and this line's job is to say which model is armed right now. `label` is the fallback
    /// for a profile that was configured by environment variables and never named a model.
    private var modelText: String {
        guard model.settings.isConfigured else { return L10n.tr("尚未选择模型") }
        let id = model.settings.profile.model.trimmingCharacters(in: .whitespacesAndNewlines)
        return id.isEmpty ? model.settings.profile.label : id
    }

    private func recentText(_ event: StatusEvent) -> String {
        let clock = event.at.formatted(date: .omitted, time: .shortened)
        guard let target = event.target else { return L10n.format("最近：%@ · %@", String(describing: event.summary), String(describing: clock)) }
        return L10n.format("最近：%@ · %@ · %@", String(describing: event.summary), String(describing: target), String(describing: clock))
    }

    // MARK: - Contents

    /// Only results that are still in memory: a `blocked` row read back from disk lost its
    /// context when the app quit, and offering to jump back to it would be a lie.
    private var waitingResults: [ActivityItem] {
        model.activity.items.filter { $0.state == .blocked && $0.isLive }
    }


    private var preconditions: [Precondition] {
        var list: [Precondition] = []
        if !model.accessibilityTrusted {
            list.append(Precondition(id: "accessibility", title: L10n.tr("达意还不能读取或替换选区")) {
                model.openAccessibilitySettings()
                dismiss()
            })
        }
        if !model.settings.isConfigured {
            list.append(Precondition(id: "model", title: L10n.tr("还没有配置模型")) {
                SettingsRoute.shared.show(.model)
                openSettings()
                dismiss()
            })
        }
        // Fatal for R1 and says so: without the hot key there is no way to reach a selection.
        if model.hotKeyFailure != nil {
            list.append(Precondition(id: "hotKey", title: L10n.tr("快捷键未注册 · 没有覆盖其他应用的快捷键")) {
                SettingsRoute.shared.show(.general)
                openSettings()
                dismiss()
            })
        }
        return list
    }

    private func openActivity() {
        openWindow(id: DayiScene.activityWindow)
        NSApp.activate()
        dismiss()
    }

    private struct Precondition: Identifiable {
        let id: String
        let title: String
        let act: () -> Void
    }
}

/// The menu bar's own label. `ResidentStatus.image` carries the palette logic; the number
/// beside it counts one thing only — 待应用, the count that implies an action. A badge on
/// every state is a badge on nothing.
struct MenuBarLabel: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: Metric.gap4) {
            if let image = model.status.image {
                Image(nsImage: image)
            } else {
                Image(systemName: "wand.and.stars")
            }
            if model.activity.pendingCount > 0 {
                Text("\(model.activity.pendingCount)")
            }
        }
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        let pending = model.activity.pendingCount
        return pending > 0 ? L10n.format("达意，待应用 %@ 条", String(describing: pending)) : L10n.format("达意，%@", String(describing: model.status.label))
    }
}

/// One row of the window-style menu. AppKit draws menu highlights for an `NSMenu`; a window
/// has to draw its own, so this is the only place in the app that keeps hover state. The
/// accent fill is the highlight, not a button: at rest the colour lives in the glyph.
private struct MenuBarRow: View {
    var symbol: String? = nil
    var tint: Color? = nil
    let title: String
    var shortcut: String? = nil
    var lineLimit = 1
    /// Drawn as the accent action even with the pointer elsewhere. Only 待应用 uses it.
    var emphasized = false
    let action: () -> Void

    @State private var highlighted = false

    private var filled: Bool { highlighted || emphasized }

    var body: some View {
        Button(action: action) {
            HStack(spacing: Metric.gap8) {
                if let symbol {
                    Image(systemName: symbol)
                        .symbolRenderingMode(.palette)
                        // A highlighted row is already accent-filled, so the mark is cut out
                        // of a white disc rather than painted onto the accent.
                        .foregroundStyle(filled ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.background),
                                         filled ? AnyShapeStyle(.white) : AnyShapeStyle(tint ?? .primary))
                        .font(.body.weight(.medium))
                        .imageScale(.medium)
                }
                Text(title).lineLimit(lineLimit).truncationMode(.tail).multilineTextAlignment(.leading)
                if let shortcut {
                    Spacer(minLength: Metric.gap12)
                    Text(shortcut)
                        .foregroundStyle(filled ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Metric.gap8)
            .padding(.vertical, Metric.gap4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(filled ? Color(nsColor: .selectedMenuItemTextColor) : Color.primary)
        .background(filled ? Color.accentColor : Color.clear,
                    in: RoundedRectangle(cornerRadius: Metric.radiusBadge))
        // The fill is inset by 4 and padded by 8, so every row's text sits at the same 12
        // as the title block and the hint rows above and below it.
        .padding(.horizontal, Metric.gap4)
        .onHover { highlighted = $0 }
    }
}
