import AppKit
import PolishCore
import SwiftUI

/// Every number the four surfaces share. The spacing scale is 4 · 8 · 12 · 16 · 20 and
/// nothing else; the widths are the ones the approved canvas measures. This is the only file
/// allowed to define a metric — a view that needs a new one adds it here first.
enum Metric {
    static let gap4: CGFloat = 4
    static let gap8: CGFloat = 8
    static let gap12: CGFloat = 12
    static let gap16: CGFloat = 16
    static let gap20: CGFloat = 20

    // Window. The window's own corner radius is the system's; a scene does not set it.
    static let windowWidth: CGFloat = 1160
    static let windowHeight: CGFloat = 680
    static let minWindowWidth: CGFloat = 720
    static let minWindowHeight: CGFloat = 420
    static let settingsWidth: CGFloat = L10n.language == "en" ? 720 : 620

    // Split view
    static let sidebarWidth: CGFloat = 190
    static let inspectorWidth: CGFloat = 300
    static let inspectorMinWidth: CGFloat = 260
    /// AppKit insets a trailing toolbar group from the window's edge; the inspector column
    /// beneath it is not inset. Subtracting this is what lands the open search field's left
    /// edge on the inspector's boundary instead of eight points inside the table. Measured
    /// through the accessibility frames on macOS 26: window right 1255, group content right
    /// 1247.
    static let toolbarTrailingInset: CGFloat = 8
    /// The open search field. It cannot be derived: 排序 and 检查器 are separate toolbar items
    /// now, and the widths AppKit gives them and the spacing it puts between them are its own.
    /// So the number is measured, and re-measured whenever the toolbar changes — the check is
    /// that the open field's left edge sits on the inspector column's boundary, which is
    /// `inspectorWidth` in from the window's right edge. Recorded in docs/design-parity.md.
    static let searchOpenWidth: CGFloat = 188
    /// What the collapsed slot is worth before the first layout has measured the real button.
    /// It is replaced by the measurement on the first frame, which is a frame with the box
    /// shut, so no animation ever runs against the guess.
    static let searchIconSlot: CGFloat = 36
    /// Below this the sidebar, the six columns at their minimums and a 260pt inspector no
    /// longer fit inside the 720 the canvas requires, so the inspector — the collapsible
    /// column — stands down rather than letting 原文 be squeezed to nothing.
    static let inspectorMinWindowWidth: CGFloat = 960

    // Table. 28pt rows with real columns beat 150pt cards. The header's own height and type
    // size are the system's: `.tableStyle(.inset)` draws it, and it already matches the 24/11
    // the canvas measures.
    static let rowHeight: CGFloat = 28
    static let tableInset: CGFloat = 12
    static let statusColumnWidth: CGFloat = 26
    static let appColumnWidth: CGFloat = 96
    /// The canvas gives 应用 and 模型 `flex:none`: every point the window gains belongs to
    /// 原文. A maximum keeps a drag possible without letting the layout hand them that space.
    static let appColumnMaxWidth: CGFloat = 140
    static let textColumnWidth: CGFloat = 200
    /// The canvas writes `min-width:0` on 原文. It still has to stay readable, so the floor
    /// is one short line rather than zero — this is what lets the whole table fit 720.
    static let textColumnMinWidth: CGFloat = 120
    static let modelColumnWidth: CGFloat = 130
    static let modelColumnMaxWidth: CGFloat = 180
    static let durationColumnWidth: CGFloat = 54
    static let timeColumnWidth: CGFloat = 76


    /// The menu bar panel. It is a window, not an `NSMenu`, so its width is ours to set.
    static let menuWidth: CGFloat = 300

    /// Sidebar row insets are the system's: `.listStyle(.sidebar)` already draws the 5×8 the
    /// canvas measures, and adding our own would stack on top of them.
    static let sidebarBadgeSize: CGFloat = 15

    // Inspector
    static let inspectorPadding: CGFloat = 16
    static let sectionGap: CGFloat = 16
    static let itemGap: CGFloat = 8
    static let labelGap: CGFloat = 4
    static let inspectorBadgeSize: CGFloat = 14
    static let footerPadding: CGFloat = 12

    // Radii. Nested radii step down by 4; nothing above 10 except the HUD capsule. The 10 on
    // the window and on the provider sheet is the system's — a scene and a `.sheet` are
    // rounded for us, and restating it here would only be a number nobody reads.
    static let radiusSelection: CGFloat = 6
    static let radiusButton: CGFloat = 6
    static let radiusBadge: CGFloat = 4
    static let radiusKeyCap: CGFloat = 4

    /// Diff fills sit behind `labelColor` text; the text itself is never coloured.
    static let additionFill: Double = 0.16
    static let removalFill: Double = 0.13

    /// The status glyph cross-fades. Rows never move as a result of a state change.
    static let glyphFade: Double = 0.15

}

/// Measurements only the Settings surfaces use. Separate from `Metric` because nothing else
/// in the app has a label column or a provider sheet, and a shared name for a number two
/// surfaces never share is how a scale rots.
enum SettingsMetric {
    /// Right-aligned label columns: 96 on 模型, 110 on 通用 and 历史.
    static let labelWidth: CGFloat = 96
    static let wideLabelWidth: CGFloat = L10n.language == "en" ? 155 : 110
    static let fieldWidth: CGFloat = 220
    static let wideFieldWidth: CGFloat = 300
    /// The hot key recorder is a field, not a button: 78×22 on the canvas.
    static let recorderWidth: CGFloat = L10n.language == "en" ? 96 : 78
    static let recorderHeight: CGFloat = 22

    // Provider sheet
    static let pickerWidth: CGFloat = 600
    static let pickerHeight: CGFloat = 420
    static let searchWidth: CGFloat = 190
    static let searchHeight: CGFloat = 24
    static let nameColumnWidth: CGFloat = 190
    static let modelColumnMinWidth: CGFloat = 140
    static let categoryColumnWidth: CGFloat = 74
    static let latencyColumnWidth: CGFloat = 88
    /// One step down, not invisible: an unverified entry is still a usable choice.
    static let unverifiedOpacity: Double = 0.7

    static let logoSize: CGFloat = 16
    static let pillLogoSize: CGFloat = 17
}

/// One rendered key. The empty state teaches the only two gestures this product has, and the
/// HUD names the next keystroke; both need a key to look like a key rather than a quotation.
struct KeyCap: View {
    enum Size {
        /// Inline in a sentence — the HUD and the inspector.
        case inline
        /// Standing on its own — the empty state.
        case standalone

        var side: CGFloat {
            switch self {
            case .inline: 18
            case .standalone: 20
            }
        }
    }

    let text: String
    var size: Size = .inline

    var body: some View {
        Text(text)
            .font(.caption)
            // The key itself is the message — `labelColor`, like every other body string.
            // Only the words explaining it ("撤回") step down to secondary; a key cap dimmer
            // than its own caption would be the wrong way round.
            .padding(.horizontal, Metric.gap4)
            .frame(minWidth: size.side, minHeight: size.side)
            .background(
                RoundedRectangle(cornerRadius: Metric.radiusKeyCap)
                    // The canvas draws a 4% fill inside a 13% border: one token, two weights.
                    .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.4))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Metric.radiusKeyCap)
                    .strokeBorder(Color(nsColor: .quaternaryLabelColor))
            )
            .accessibilityLabel(text)
    }
}

/// A shortcut as separate keys — "⌃⌥P" is three caps, not one wide one.
struct KeyCapRow: View {
    let shortcut: String
    var size: KeyCap.Size = .standalone

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(shortcut.enumerated()), id: \.offset) { _, key in
                KeyCap(text: String(key), size: size)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(shortcut)
    }
}

/// 状态 / 目标 / 模型 / 原文 / 润色后. Never uppercased: this app has no uppercase headers.
struct InspectorSectionHeader: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }
}

/// The status column's entire content. It carries the accessibility name for the row's state
/// because the column has no visible text to read.
extension View {
    /// A `.fill` glyph is two layers: the mark, and the disc or triangle behind it. Handed a
    /// single palette colour both layers take it and the glyph flattens into a coloured blob
    /// — the state stops being a shape, which is the one thing DESIGN.md §12 forbids. The
    /// mark is painted with the surface behind the glyph, so it reads as a hole cut out of
    /// the disc in both appearances instead of a hard-coded white.
    func filledGlyph(_ tint: some ShapeStyle) -> some View {
        symbolRenderingMode(.palette).foregroundStyle(.background, tint)
    }
}

struct StateGlyph: View {
    let state: ActivityState
    var scale: Image.Scale = .medium
    /// A selected row paints its own foreground; the glyph follows it instead of keeping a
    /// tint that would fail against the accent fill.
    var emphasized = false
    /// The cross-fade is the component's, so every caller gets Reduce Motion for free rather
    /// than remembering to wrap this in a transaction of its own.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        content
            .accessibilityLabel(state.name)
            .animation(reduceMotion ? nil : .easeInOut(duration: Metric.glyphFade), value: state)
    }

    /// The ring. On a selected row it goes white, the way the canvas draws it, because the
    /// tint would sit on the accent fill at nearly no contrast.
    private var disc: AnyShapeStyle {
        emphasized ? AnyShapeStyle(.white) : AnyShapeStyle(state.tint ?? .primary)
    }

    /// The mark inside the ring. It is not white — it is whatever is behind the glyph, so the
    /// mark reads as a hole cut out of the disc in both appearances and on a selected row.
    private var mark: AnyShapeStyle {
        emphasized
            ? AnyShapeStyle(Color(nsColor: .selectedContentBackgroundColor))
            : AnyShapeStyle(Color(nsColor: .textBackgroundColor))
    }

    @ViewBuilder private var content: some View {
        switch state {
        case .running, .applying:
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.small)
        default:
            Image(systemName: state.symbol)
                .symbolRenderingMode(.palette)
                .foregroundStyle(state.hasMarkLayer ? mark : disc, disc)
                .imageScale(scale)
                .font(.body.weight(.medium))
        }
    }
}

/// The small square in front of an application name. The real icon when the application is
/// running, and a stable coloured initial when it is not — a history row outlives the process
/// it names, and the sidebar must not reshuffle its colours when that happens.
struct AppBadge: View {
    let label: String
    var size: CGFloat = Metric.sidebarBadgeSize

    var body: some View {
        Group {
            if let icon = AppIconCache.icon(for: label) {
                Image(nsImage: icon).resizable().interpolation(.high)
            } else {
                RoundedRectangle(cornerRadius: Metric.radiusBadge)
                    .fill(Self.fallbackColor(for: label))
                    .overlay(
                        Text(initial)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .minimumScaleFactor(0.5)
                    )
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var initial: String {
        label.first.map { String($0).uppercased() } ?? "·"
    }

    /// `Hasher` is seeded per process, so the same application would change colour on every
    /// launch. This fold does not.
    private static func fallbackColor(for label: String) -> Color {
        var hash: UInt64 = 5381
        for scalar in label.unicodeScalars { hash = hash &* 33 &+ UInt64(scalar.value) }
        return Color(hue: Double(hash % 360) / 360, saturation: 0.5, brightness: 0.68)
    }
}

/// Icons are read once per application. A running application's icon does not change while
/// this window is open, and looking it up walks the whole process list.
@MainActor
private enum AppIconCache {
    private static var icons: [String: NSImage] = [:]

    static func icon(for label: String) -> NSImage? {
        if let cached = icons[label] { return cached }
        guard let icon = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == label })?.icon else {
            return nil
        }
        icons[label] = icon
        return icon
    }
}

/// Provider logos from the bundled catalogue. A monochrome logo is a template so the
/// surrounding appearance colours it; a coloured one is left alone. Without a logo the
/// placeholder is a generic cloud, so the rows stay aligned.
@MainActor
enum ProviderIcon {
    /// Keyed by name *and* size: an `NSImage` carries its size, and the menu (12), the
    /// settings form (16) and the inspector (15) draw the same file at once.
    private static var cache: [String: NSImage] = [:]
    private static let websiteCatalog = try? ProviderCatalog.bundled()

    /// Reuse bundled brand artwork without sending browsing domains to a favicon service.
    static func websiteImage(for host: String, size: CGFloat = Metric.sidebarBadgeSize) -> Image? {
        let name: String
        switch host {
        case "chatgpt.com", "www.chatgpt.com", "chat.openai.com": name = "openai.svg"
        case "gemini.google.com": name = "gemini.svg"
        case "chat.deepseek.com": name = "deepseek.svg"
        default: return nil
        }
        guard let catalog = websiteCatalog,
              let preset = catalog.providers.first(where: { $0.icon == name }),
              let image = load(name, from: catalog.iconURL(for: preset), size: size) else {
            return nil
        }
        return Image(nsImage: image)
    }

    static func image(for preset: ProviderPreset, in catalog: ProviderCatalog?, size: CGFloat = 16) -> Image {
        guard let catalog, let icon = preset.icon,
              let image = load(icon, from: catalog.iconURL(for: preset), size: size) else {
            return Image(systemName: "cloud")
        }
        return Image(nsImage: image)
    }

    private static func load(_ name: String, from url: URL?, size: CGFloat) -> NSImage? {
        let key = "\(name)@\(size)"
        if let cached = cache[key] { return cached }
        guard let url, let image = NSImage(contentsOf: url) else { return nil }
        image.size = NSSize(width: size, height: size)
        image.isTemplate = ProviderIcon.monochrome.contains(name)
        cache[key] = image
        return image
    }

    /// Logos drawn in a single dark colour; the rest carry their brand colours.
    static let monochrome: Set<String> = ["anthropic.svg", "bailian.svg", "openai.svg", "openrouter.svg", "xai.svg", "novita.svg", "opencode-logo-light.svg"]
}
