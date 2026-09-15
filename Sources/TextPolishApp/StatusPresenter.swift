import AppKit
import ApplicationServices
import PolishCore
import SwiftUI

/// One press produces one line of feedback. The menu bar carries the resident state; this
/// capsule only answers "did that press do anything", next to where the press happened. It
/// can never be clicked — taking focus would make Dayi frontmost, which is the exact
/// condition capture rejects — so its whole job is to name the next keystroke precisely.
struct StatusEvent: Equatable {
    /// What happened, at the granularity the capsule draws: one glyph, one dwell, one short
    /// name for the menu bar's 最近 line. Deliberately not `ActivityState`: the capsule also
    /// answers presses that never became a job — waking a host, a missing permission.
    enum Kind: Equatable {
        case waking, polishing, applying, undoing
        case applied, waiting, undone
        case failed, uncertain, unauthorized
    }

    let kind: Kind
    /// The whole sentence, naming the application: "已替换" is useless, "已替换 Codex 的选区" is not.
    let text: String
    /// Which application the press was about, for the menu bar's 最近 line. Separate from the
    /// sentence because two states deliberately do not print it.
    let target: String?
    /// The key the sentence ends on. A waiting result must end on a real keystroke.
    let keyCap: String?
    /// What that key does, where the sentence does not already say it.
    let keyNote: String?
    /// When the work started. Only the spinning kinds carry one, and the capsule counts up
    /// from it: measured latency spans 2.3–19.3s, so "still working" is not an answer.
    let startedAt: Date?
    let at: Date

    private init(_ kind: Kind, _ text: String, target: String? = nil, keyCap: String? = nil,
                 keyNote: String? = nil, startedAt: Date? = nil) {
        self.kind = kind
        self.text = text
        self.target = target
        self.keyCap = keyCap
        self.keyNote = keyNote
        self.startedAt = startedAt
        at = Date()
    }

    /// A failure stays long enough to read after looking away; the rest acknowledge and go.
    var dwell: Duration {
        switch kind {
        case .failed, .uncertain, .unauthorized: .seconds(10)
        case .waking, .polishing, .applying, .undoing: .seconds(3)
        case .applied, .waiting, .undone: .seconds(2)
        }
    }

    /// The kinds that are still in flight draw a `ProgressView` where the glyph goes.
    var showsProgress: Bool {
        switch kind {
        case .waking, .polishing, .applying, .undoing: true
        case .applied, .waiting, .undone, .failed, .uncertain, .unauthorized: false
        }
    }

    var symbol: String {
        switch kind {
        case .applied: "checkmark.circle.fill"
        case .waiting: "arrow.right.circle.fill"
        case .undone: "arrow.uturn.backward.circle"
        case .failed: "xmark.circle.fill"
        case .uncertain, .unauthorized: "exclamationmark.triangle.fill"
        // Never drawn in the capsule; it is here so a surface that cannot spin a
        // `ProgressView` still has a shape for these kinds.
        case .waking, .polishing, .applying, .undoing: "circle.dashed"
        }
    }

    /// Colour lives in the glyph. The sentence stays `labelColor` in every single state.
    var tint: Color {
        switch kind {
        case .applied: .green
        case .waiting, .unauthorized: .orange
        case .failed, .uncertain: .red
        case .undone: Color(nsColor: .secondaryLabelColor)
        case .waking, .polishing, .applying, .undoing: .accentColor
        }
    }

    /// The short name the menu bar's 最近 line uses: "最近：已替换 · Codex · 14:32".
    var summary: String {
        switch kind {
        case .waking: L10n.tr("唤醒中")
        case .polishing: L10n.tr("润色中")
        case .applying: L10n.tr("正在应用")
        case .undoing: L10n.tr("正在撤回")
        case .applied: L10n.tr("已替换")
        case .waiting: L10n.tr("待应用")
        case .undone: L10n.tr("已撤回")
        case .failed: L10n.tr("请求失败")
        case .uncertain: L10n.tr("写入不确定")
        case .unauthorized: L10n.tr("未授权")
        }
    }
}

/// The seven sentences, in one place. Every construction site in `AppModel` names one of
/// these rather than assembling a string, so the wording cannot drift between two presses
/// that mean the same thing.
///
/// `@MainActor` because four of them end on a key cap and both keys are rebindable: the
/// combination is read off the live registration at the moment the capsule is built. Every
/// caller is already on the main actor, so nothing hops.
@MainActor
extension StatusEvent {
    static func waking(_ app: String) -> StatusEvent {
        StatusEvent(.waking, L10n.format("正在唤醒 %@ 的输入区…", String(describing: app)), target: app)
    }

    static func polishing(_ app: String) -> StatusEvent {
        StatusEvent(.polishing, L10n.format("润色 %@ 的选区…", String(describing: app)), target: app, startedAt: Date())
    }

    static func applying(_ app: String) -> StatusEvent {
        StatusEvent(.applying, L10n.format("正在写回 %@ 的选区…", String(describing: app)), target: app, startedAt: Date())
    }

    static func undoing(_ app: String) -> StatusEvent {
        StatusEvent(.undoing, L10n.format("正在撤回 %@ 的替换…", String(describing: app)), target: app, startedAt: Date())
    }

    static func applied(_ app: String) -> StatusEvent {
        StatusEvent(.applied, L10n.format("已替换 %@ 的选区", String(describing: app)), target: app,
                    keyCap: HotKeyBindings.shared.undo.display, keyNote: L10n.tr("撤回"))
    }

    /// The one message that must end on a literal keystroke: nothing else will apply this
    /// result, and the context dies with the target application.
    static func waiting(_ app: String) -> StatusEvent {
        StatusEvent(.waiting, L10n.format("结果已备好 · 回到 %@ 按", String(describing: app)), target: app,
                    keyCap: HotKeyBindings.shared.polish.display)
    }

    static func undone(_ app: String) -> StatusEvent {
        StatusEvent(.undone, L10n.format("已撤回 %@ 的替换", String(describing: app)), target: app)
    }

    /// The one sentence that does not name the application: nothing was confirmed, so naming
    /// a target would claim more than the app knows.
    static func uncertain(_ app: String?) -> StatusEvent {
        StatusEvent(.uncertain, L10n.tr("无法确认写入结果 · 已停止自动操作"), target: app)
    }

    static func unauthorized() -> StatusEvent {
        StatusEvent(.unauthorized, L10n.tr("达意还没有辅助功能权限"))
    }

    static func nothingToUndo() -> StatusEvent {
        StatusEvent(.failed, L10n.tr("没有可撤回的替换"))
    }

    /// A model or network error that came back with a job attached.
    static func requestFailed(_ app: String, reason: String?) -> StatusEvent {
        StatusEvent(.failed, reason.map { "\(app)：\($0)" } ?? L10n.format("%@ 的润色请求未完成", String(describing: app)), target: app)
    }

    /// A press that never became a job. `app` is whatever was frontmost when the key went
    /// down, which is the only name that exists before a target does.
    static func failure(_ error: Error, app: String?) -> StatusEvent {
        if let appError = error as? AppError, case .accessibilityRequired = appError { return .unauthorized() }
        if let target = error as? TargetError {
            switch target {
            case .noFocusedInput:
                return StatusEvent(.failed, L10n.format("%@ 里没有找到输入焦点 · 点进输入框再按", String(describing: app ?? L10n.tr("这个应用"))),
                                   target: app, keyCap: HotKeyBindings.shared.polish.display)
            case .unsupportedInput:
                return StatusEvent(.failed, L10n.format("%@ 的焦点不在可润色的文字输入区", String(describing: app ?? L10n.tr("这个应用"))),
                                   target: app, keyCap: HotKeyBindings.shared.polish.display)
            case .hostForeground:
                return StatusEvent(.failed, L10n.tr("达意在最前面 · 切回目标应用再按"),
                                   keyCap: HotKeyBindings.shared.polish.display)
            case .uncertain:
                return .uncertain(app)
            default:
                break
            }
        }
        return StatusEvent(.failed, app.map { "\($0)：\(error.localizedDescription)" } ?? error.localizedDescription,
                           target: app)
    }
}

/// The resident answer to "is it on right now", read off the live job list.
enum ResidentStatus: Equatable {
    case blocked(String)
    case running(Int)
    case attention(Int)
    case ready

    var label: String {
        switch self {
        case .blocked(let reason): reason
        case .running(let count): L10n.format("润色中 ×%@", String(describing: count))
        case .attention(let count): L10n.format("待处理 ×%@", String(describing: count))
        case .ready: L10n.tr("就绪")
        }
    }

    var badge: String? {
        switch self {
        case .running(let count), .attention(let count): count > 1 ? "\(count)" : nil
        case .blocked, .ready: nil
        }
    }

    private var symbol: String {
        switch self {
        case .blocked: "exclamationmark.triangle.fill"
        case .running: "wand.and.rays"
        case .attention: "wand.and.stars.inverse"
        case .ready: "wand.and.stars"
        }
    }

    /// Only the resting state follows the menu bar's own colour; the others must read as
    /// a state change from the corner of an eye. A palette colours a layered symbol from
    /// the innermost layer out, so the warning mark is named before its triangle.
    private var palette: [NSColor] {
        switch self {
        case .blocked: [.white, .systemRed]
        case .running: [.systemBlue]
        case .attention: [.systemOrange]
        case .ready: []
        }
    }

    var image: NSImage? {
        if case .ready = self, let image = Self.brandImage { return image }
        guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label) else { return nil }
        var configuration = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        if !palette.isEmpty { configuration = configuration.applying(.init(paletteColors: palette)) }
        let configured = image.withSymbolConfiguration(configuration) ?? image
        configured.isTemplate = palette.isEmpty
        return configured
    }

    private static let brandImage: NSImage? = {
        guard let url = Bundle.main.url(forResource: "Dayi", withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        return image
    }()
}

/// A glyph, a sentence, and — where it matters — the key to press next. Nothing in here is
/// a control: the moment this can take a click, Dayi is the frontmost application and the
/// capture path refuses to run. The capsule is translucent because it genuinely floats over
/// another application's window and must not look like it belongs to that app.
private struct StatusCapsule: View {
    let event: StatusEvent

    var body: some View {
        HStack(spacing: Metric.gap8) {
            glyph
            Text(event.text)
                .font(.body.weight(.medium))
                .foregroundStyle(Color.primary)
                .lineLimit(1)
            if let start = event.startedAt { ElapsedSeconds(start: start) }
            if let keyCap = event.keyCap { KeyCap(text: keyCap) }
            if let note = event.keyNote {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
        }
        // The canvas measures 9 × 14 around the capsule; it is the one surface off the
        // 4 · 8 · 12 · 16 · 20 scale, because a capsule's ends eat their own padding.
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color(nsColor: .separatorColor)))
        .fixedSize()
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var glyph: some View {
        if event.showsProgress {
            ProgressView().controlSize(.small)
        } else {
            Image(systemName: event.symbol)
                .filledGlyph(event.tint)
                .font(.body.weight(.medium))
                .imageScale(.large)
        }
    }
}

/// How long this press has been running, counting up in place. The panel's frame is measured
/// once, when it is shown, so the widest reading is reserved up front and the capsule never
/// resizes mid-count.
private struct ElapsedSeconds: View {
    let start: Date

    var body: some View {
        TimelineView(.periodic(from: start, by: 0.1)) { context in
            ZStack(alignment: .trailing) {
                Text(Self.reading(99.9)).hidden()
                Text(Self.reading(context.date.timeIntervalSince(start)))
            }
        }
        .font(.system(.caption, design: .monospaced))
        .foregroundStyle(.tertiary)
    }

    private static func reading(_ seconds: Double) -> String {
        String(format: "%.1fs", max(0, seconds))
    }
}

/// A borderless, click-through, non-activating window above every other window and space.
/// It must never become key: taking the foreground would make Dayi itself the frontmost
/// application, which is exactly the condition capture and the paste write path reject.
@MainActor
final class StatusHUD {
    private var dismissal: Task<Void, Never>?

    private lazy var panel: NSPanel = {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        return panel
    }()

    func show(_ event: StatusEvent) {
        dismissal?.cancel()
        let view = NSHostingView(rootView: StatusCapsule(event: event))
        let size = view.fittingSize
        view.frame = CGRect(origin: .zero, size: size)
        panel.contentView = view
        panel.setFrame(CGRect(origin: origin(for: size), size: size), display: false)
        // A press during the previous fade must interrupt that animation, not inherit it.
        setAlpha(1, over: 0)
        panel.orderFrontRegardless()
        dismissal = Task { [weak self] in
            try? await Task.sleep(for: event.dwell)
            guard !Task.isCancelled, let self else { return }
            let duration = dismissDuration
            setAlpha(0, over: duration)
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            panel.orderOut(nil)
        }
    }

    private let fade = 0.25

    /// This is an `NSPanel` driven by `NSAnimationContext`, and AppKit does not switch that
    /// off for Reduce Motion the way SwiftUI does — so the workspace flag is read directly.
    /// Appearing is already instantaneous (`animationBehavior = .none`); only the fade is
    /// motion, and under the setting the capsule simply stops being there.
    private var dismissDuration: TimeInterval {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : fade
    }

    private func setAlpha(_ alpha: CGFloat, over duration: TimeInterval) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            panel.animator().alphaValue = alpha
        }
    }

    private func origin(for size: CGSize) -> CGPoint {
        let main = NSScreen.main?.visibleFrame ?? .zero
        guard let caret = CaretAnchor.rect() else {
            return CGPoint(x: main.maxX - size.width - 16, y: main.maxY - size.height - 16)
        }
        let screen = NSScreen.screens.first { $0.frame.intersects(caret) }?.visibleFrame ?? main
        var y = caret.minY - 10 - size.height
        if y < screen.minY { y = caret.maxY + 10 }
        return CGPoint(x: min(max(caret.minX, screen.minX + 8), screen.maxX - size.width - 8),
                       y: min(max(y, screen.minY + 8), screen.maxY - size.height - 8))
    }
}

/// Where the caret currently sits, in AppKit screen coordinates. Read-only: this asks the
/// focused element for its geometry and writes nothing, so it never disturbs a target.
private enum CaretAnchor {
    static func rect() -> CGRect? {
        guard AXIsProcessTrusted() else { return nil }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.2)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.2)
        guard let rect = selectionBounds(element) ?? fieldFrame(element),
              let primary = NSScreen.screens.first else { return nil }
        // Accessibility measures down from the top-left of the primary screen.
        let flipped = CGRect(x: rect.minX, y: primary.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
        guard NSScreen.screens.contains(where: { $0.frame.intersects(flipped) }) else { return nil }
        return flipped
    }

    private static func selectionBounds(_ element: AXUIElement) -> CGRect? {
        var range: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &range) == .success,
              let range, CFGetTypeID(range) == AXValueGetTypeID() else { return nil }
        var bounds: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXBoundsForRangeParameterizedAttribute as CFString, range, &bounds) == .success,
              let bounds, CFGetTypeID(bounds) == AXValueGetTypeID() else { return nil }
        return cgRect(bounds as! AXValue)
    }

    /// Without a caret rectangle only the whole control is known. A short field still points
    /// at the text; a tall one would drop the message a screen away from it, so it is refused
    /// and the caller falls back to the fixed corner.
    private static let fieldHeightLimit: CGFloat = 120

    private static func fieldFrame(_ element: AXUIElement) -> CGRect? {
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, "AXFrame" as CFString, &value) == .success,
           let value, CFGetTypeID(value) == AXValueGetTypeID(), let rect = cgRect(value as! AXValue) {
            return rect.height <= fieldHeightLimit ? rect : nil
        }
        var position: CFTypeRef?
        var size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size,
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin),
              AXValueGetValue(size as! AXValue, .cgSize, &extent),
              extent.height > 0, extent.height <= fieldHeightLimit else { return nil }
        return CGRect(origin: origin, size: extent)
    }

    private static func cgRect(_ value: AXValue) -> CGRect? {
        var rect = CGRect.zero
        guard AXValueGetValue(value, .cgRect, &rect), rect.height > 0 else { return nil }
        return rect
    }
}
