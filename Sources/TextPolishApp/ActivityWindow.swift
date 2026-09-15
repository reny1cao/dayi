import AppKit
import PolishCore
import SwiftUI

/// State this window shares with commands that are built in another scene. The menu bar owns
/// ⌥⌘I and ⌘F but cannot reach into a window's `@State`, so the pieces both sides touch live
/// under keys instead of being passed down.
enum ActivityWindowState {
    /// Bind `@AppStorage(ActivityWindowState.inspectorVisibility)` from a command to toggle
    /// the inspector of every open activity window.
    static let inspectorVisibility = "activity.showsInspector"
}

/// 活动 —— the whole window. It is opened rarely, and when it is opened it is to rescue a
/// result that could not be written back, to read one that was, or to fix a precondition.
/// There is no primary action in the toolbar: the primary action is a hot key in somebody
/// else's application, and a 润色 button here would have nothing to read.
struct ActivityWindow: View {
    private let model: AppModel
    @Bindable private var store: ActivityStore
    @AppStorage(ActivityWindowState.inspectorVisibility) private var showsInspector = true
    @State private var columns = NavigationSplitViewVisibility.automatic
    /// Bumped to move the keyboard into the search field. A token rather than a `Bool` so the
    /// request cannot get stuck on and steal focus back on every redraw.
    @State private var searchFocus = 0
    /// True while the keyboard is inside the search field. The 编辑 menu binds bare ⌫ and ↩,
    /// and a menu key equivalent outranks the responder chain — so those two commands have to
    /// stand down while somebody is typing, or a backspace would delete the selected records.
    @State private var searchEditing = false
    /// The search box starts as an icon. This window's list is short and usually browsed by
    /// the sidebar, so a permanently open field would spend the toolbar's width on the least
    /// used control — and the canvas puts that width where the inspector column is.
    @State private var searchExpanded = false
    /// The collapsed magnifier at whatever size the system draws it, so the animation has a
    /// real number to start from rather than a guess that goes stale with the next SDK.
    @State private var collapsedSlot = Metric.searchIconSlot
    @State private var confirmingClear = false
    /// The split view's own width, watched so the inspector can stand down before the table
    /// is squeezed past its columns' minimums. Starts at the default so a window that opens
    /// wide never flickers the inspector out and back in.
    @State private var splitWidth = Metric.windowWidth
    @Environment(\.openSettings) private var openSettings

    init(model: AppModel) {
        self.model = model
        _store = Bindable(model.activity)
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            ActivitySidebar(store: store)
                .navigationSplitViewColumnWidth(min: 170, ideal: Metric.sidebarWidth, max: 260)
        } detail: {
            detail
                .inspector(isPresented: inspectorPresented) {
                    RecordInspector(store: store)
                        .inspectorColumnWidth(min: Metric.inspectorMinWidth,
                                              ideal: Metric.inspectorWidth, max: 420)
                }
                .toolbar { toolbar }
        }
        .navigationSplitViewStyle(.balanced)
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { splitWidth = proxy.size.width }
                    .onChange(of: proxy.size.width) { splitWidth = proxy.size.width }
            }
        }
        // The title bar carries the current list and its size — the two things a toolbar
        // title should say when the window has no action to offer.
        .navigationTitle(filterTitle)
        .navigationSubtitle(L10n.format("%@ 条", String(describing: store.visibleItems.count)))
        .frame(minWidth: Metric.minWindowWidth, minHeight: Metric.minWindowHeight)
        // Everything the menu bar drives from another scene, published in one line. It goes
        // away when this window stops being the front one, which is exactly when none of
        // those commands mean anything.
        .focusedSceneValue(\.activity, ActivityFocus(
            store: store,
            // ⌘F asks once. A token rather than a latched `Bool`, so the request cannot get
            // stuck on and steal the keyboard back on every redraw.
            search: Binding(get: { false }, set: { if $0 { openSearch() } }),
            inspector: $showsInspector,
            clearConfirmation: $confirmingClear,
            isEditingText: searchEditing
        ))
        // An empty box that has lost the keyboard has nothing to say, so it goes back to
        // being an icon. A box with a query in it stays open however focus moves: the query
        // is filtering the table, and hiding the reason a list looks short is worse than
        // spending the width.
        .onChange(of: searchEditing) { _, editing in
            guard !editing, store.query.isEmpty else { return }
            searchExpanded = false
        }
        .confirmationDialog(L10n.format("清空全部 %@ 条记录？", String(describing: store.totalCount)), isPresented: $confirmingClear) {
            Button(L10n.tr("清空历史"), role: .destructive) { store.clearAll() }
            Button(L10n.tr("取消"), role: .cancel) {}
        } message: {
            Text(L10n.tr("记录和正文都会从数据库删除，无法恢复。"))
        }
    }

    /// The canvas requires this window to work at 720×420, and at that width the sidebar, the
    /// six columns at their minimums and a 260pt inspector do not fit — the table would clip
    /// 模型, 耗时 and 时间 and squeeze 原文 to nothing, which destroys the one thing this window
    /// is for. The inspector is the collapsible column (⌥⌘I), so it is what gives way. The
    /// person's own choice is not overwritten: it comes back when the window is widened.
    private var inspectorPresented: Binding<Bool> {
        Binding(get: { showsInspector && splitWidth >= Metric.inspectorMinWindowWidth },
                set: { showsInspector = $0 })
    }

    // MARK: - Detail

    private var detail: some View {
        VStack(spacing: 0) {
            banners
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }

    @ViewBuilder private var content: some View {
        if store.isEmpty {
            EmptyRecords()
        } else if store.hasNoMatches {
            NoMatches(store: store, filterTitle: filterTitle)
        } else {
            RecordTable(store: store)
        }
    }

    /// The four preconditions from the design's non-record table. Each one is a banner with a
    /// button that fixes it, never a red screen: history stays readable while any of them is
    /// broken. They carry no close button because `watchPermission()` polls every 3s and a
    /// dismissed banner would only hide a product that still cannot work.
    @ViewBuilder private var banners: some View {
        if !model.accessibilityTrusted {
            PreconditionBanner(
                title: L10n.tr("达意还不能读取或替换选区"),
                detail: L10n.tr("系统设置 → 隐私与安全性 → 辅助功能，勾选这个应用。"),
                actionTitle: L10n.tr("打开系统设置"),
                isProminent: true
            ) { model.openAccessibilitySettings() }
        }
        if !model.settings.isConfigured {
            PreconditionBanner(
                title: L10n.tr("还没有配置模型"),
                detail: catalogueNote,
                actionTitle: L10n.tr("设置… ⌘,")
            ) { open(.model) }
        }
        if let failure = model.hotKeyFailure {
            // Fatal for R1, and the banner has to say so: without a hot key over other
            // applications there is no way to reach a selection at all. The `OSStatus` line
            // follows, because that is what tells a conflicting app apart from a missing
            // entitlement.
            PreconditionBanner(title: L10n.tr("快捷键未注册"),
                               detail: L10n.format("没有覆盖其他应用的快捷键。%@", String(describing: failure)),
                               actionTitle: L10n.tr("打开设置…")) {
                open(.general)
            }
        }
        if let failure = model.history.failure {
            PreconditionBanner(title: L10n.tr("历史记录未能保存"), detail: failure)
        }
    }

    /// What this project actually knows about the catalogue, counted rather than written down:
    /// 39 of 42 entries have never had a request sent to them, and saying so is the difference
    /// between a choice and a menu.
    private var catalogueNote: String {
        guard let catalog = Self.catalog else { return L10n.tr("选定服务商并填入 API Key 之后就能发出请求。") }
        let verified = catalog.providers.filter(\.verified).count
        return L10n.format("%@ 家服务商可选，其中 %@ 家在达意里实测过。", String(describing: catalog.providers.count), String(describing: verified))
    }

    /// Decoded once: 42 entries of JSON, read only to count them.
    private static let catalog = try? ProviderCatalog.bundled()

    // MARK: - Toolbar

    /// `openSettings()` cannot say which tab, and every banner here means one specific one.
    private func open(_ tab: SettingsScene.Tab) {
        SettingsRoute.shared.show(tab)
        openSettings()
    }

    /// Open, or holding a query that is filtering the table.
    private var searchIsOpen: Bool { searchExpanded || !store.query.isEmpty }

    private func openSearch() {
        searchExpanded = true
        searchFocus += 1
    }

    /// A click that landed anywhere but in the field. A box with a query in it stays open —
    /// the query is filtering the table, and hiding the reason a list looks short is worse
    /// than spending the width. An empty one has nothing to say and goes back to being an
    /// icon.
    private func collapseSearchIfEmpty() {
        guard store.query.isEmpty else { return }
        searchExpanded = false
    }

    /// Three items, not one. macOS draws a container behind each toolbar item, so a single
    /// item wide enough to hold the open field draws that container around the empty half too
    /// while the box is shut — a long blank capsule with the controls crammed into its right
    /// end. Separate items each get their own, which is also what the canvas draws.
    ///
    /// Trailing items are laid out from the window's edge inwards, so the two buttons keep
    /// their distance from that edge while the search item to their left changes width. The
    /// open field's left edge lands on the inspector column's boundary.
    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem {
            // Overlaid, not swapped in place. An `if`/`else` in a stack keeps both children in
            // the layout for as long as they cross-fade, and their combined width moves
            // whatever sits beside them for the length of the fade.
            ZStack(alignment: .trailing) {
                if searchIsOpen {
                    RecordSearchField(text: $store.query, focusToken: searchFocus,
                                      isEditing: $searchEditing, prompt: L10n.tr("搜索记录"),
                                      onClickOutside: collapseSearchIfEmpty)
                        .frame(maxWidth: .infinity)
                } else {
                    Button { openSearch() } label: {
                        Label(L10n.tr("搜索记录"), systemImage: "magnifyingglass")
                    }
                    .help(L10n.tr("搜索记录（⌘F）"))
                    .background { measuring($collapsedSlot) }
                }
            }
            .frame(width: searchIsOpen ? openSlot : collapsedSlot, alignment: .trailing)
            // No animation, and none is possible here. A `ToolbarItem`'s content is hosted
            // outside the window's own view tree, and an implicit animation on its layout
            // does not run: filmed at 60fps with the duration stretched to two seconds, the
            // width still changed in a single frame. What the animation modifier bought was
            // one frame of the outgoing icon drawn at the incoming geometry — a magnifier
            // flashing at the far left — and nothing else. The box opens in one frame, which
            // is also the only way the two buttons beside it are guaranteed never to move.
        }
        ToolbarItem {
            SortMenu(store: store)
        }
        ToolbarItem {
            Button { showsInspector.toggle() } label: {
                Label(L10n.tr("检查器"), systemImage: "sidebar.trailing")
                    // The accent outline follows the column that is actually on screen, not
                    // the stored preference: in a narrow window the inspector has stood down
                    // and a lit button would be claiming a column nobody can see.
                    .foregroundStyle(inspectorPresented.wrappedValue
                                     ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
            }
            .help(L10n.tr("显示或隐藏检查器（⌥⌘I）"))
        }
    }

    /// Both ends of the slot's animation are numbers, because SwiftUI cannot interpolate from
    /// an intrinsic width to a stated one.
    private var openSlot: CGFloat { max(collapsedSlot, Metric.searchOpenWidth) }

    private func measuring(_ width: Binding<CGFloat>) -> some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear { width.wrappedValue = proxy.size.width }
                .onChange(of: proxy.size.width) { width.wrappedValue = proxy.size.width }
        }
    }

    private var filterTitle: String {
        switch store.filter {
        case .pending: L10n.tr("待应用")
        case .unfinished: L10n.tr("未完成")
        case .all: L10n.tr("全部活动")
        case .app(let label): label
        case .website(let host): host
        }
    }
}

// MARK: - Sort

/// The control the canvas draws between the search field and the inspector toggle. It is a
/// sort menu and not a filter: the sidebar is already the filter, and a second one would be
/// the furniture the design system refuses. Every entry here is a column header the pointer
/// can already click — this is the route for the keyboard and for a window narrow enough that
/// the headers have stopped being obvious targets. It carries no state of its own.
private struct SortMenu: View {
    let store: ActivityStore

    var body: some View {
        Menu {
            Picker(L10n.tr("排序依据"), selection: field) {
                ForEach(ActivitySort.Field.allCases, id: \.self) { field in
                    Text(Self.title(field)).tag(field)
                }
            }
            .pickerStyle(.inline)
            Divider()
            Picker(L10n.tr("顺序"), selection: ascending) {
                Text(L10n.tr("升序")).tag(true)
                Text(L10n.tr("降序")).tag(false)
            }
            .pickerStyle(.inline)
        } label: {
            Label(L10n.tr("排序"), systemImage: "line.3.horizontal.decrease.circle")
        }
        .help(L10n.tr("按列排序"))
    }

    private var field: Binding<ActivitySort.Field> {
        Binding { store.sortOrder.field } set: { store.sortOrder.field = $0 }
    }

    private var ascending: Binding<Bool> {
        Binding { store.sortOrder.ascending } set: { store.sortOrder.ascending = $0 }
    }

    /// The column headers, verbatim. 状态 has no visible header in the table, so this is the
    /// one place its name is written down for a reader rather than for VoiceOver.
    private static func title(_ field: ActivitySort.Field) -> String {
        switch field {
        case .state: L10n.tr("状态")
        case .app: L10n.tr("来源")
        case .model: L10n.tr("模型")
        case .duration: L10n.tr("耗时")
        case .time: L10n.tr("时间")
        }
    }
}

// MARK: - Sidebar

/// 待应用 is first, and is not sorted with the rest, because it is the only list with an
/// expiring value: those results die when the app quits. Badges appear only on the two lists
/// that imply an action — a badge on everything is a badge on nothing.
private struct ActivitySidebar: View {
    let store: ActivityStore

    var body: some View {
        List(selection: selection) {
            SidebarRow(title: L10n.tr("待应用"), count: store.pendingCount, style: .inbox) {
                StateGlyph(state: .blocked)
            }
            .tag(ActivityStore.Filter.pending)

            SidebarRow(title: L10n.tr("未完成"), count: store.unfinishedCount, style: .attention) {
                StateGlyph(state: .uncertain)
            }
            .tag(ActivityStore.Filter.unfinished)

            SidebarRow(title: L10n.tr("全部活动"), count: store.totalCount, style: .plain) {
                Image(systemName: "list.bullet")
                    .font(.body.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .tag(ActivityStore.Filter.all)

            Section(L10n.tr("应用")) {
                ForEach(store.apps, id: \.label) { app in
                    SidebarRow(title: app.label, count: app.count, style: .plain) {
                        AppBadge(label: app.label)
                    }
                    .tag(ActivityStore.Filter.app(app.label))
                }
            }
            if !store.websites.isEmpty {
                Section(L10n.tr("网站")) {
                    ForEach(store.websites, id: \.host) { site in
                        SidebarRow(title: site.host, count: site.count, style: .plain) {
                            WebsiteBadge(host: site.host)
                        }
                        .tag(ActivityStore.Filter.website(site.host))
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    /// The store decides which list is shown when nobody has chosen one; deselecting is not
    /// one of the choices, so an empty selection is ignored rather than written back.
    private var selection: Binding<ActivityStore.Filter?> {
        Binding {
            store.filter
        } set: { filter in
            guard let filter else { return }
            store.filter = filter
        }
    }
}

private enum SidebarCountStyle {
    /// The inbox: an accent badge, the one place in this window colour marks an action.
    case inbox
    /// Something went wrong and is still countable, but nothing is expiring.
    case attention
    /// A number, not a badge.
    case plain
}

private struct SidebarRow<Icon: View>: View {
    let title: String
    let count: Int
    let style: SidebarCountStyle
    @ViewBuilder let icon: Icon

    var body: some View {
        HStack(spacing: Metric.gap8) {
            icon.frame(width: Metric.sidebarBadgeSize, height: Metric.sidebarBadgeSize)
            Text(title).lineLimit(1)
            Spacer(minLength: Metric.gap8)
            switch style {
            // An empty inbox is the resting state, not a task worth a coloured pill: §3 puts
            // badges only on counts that imply an action, and 0 implies none.
            case .inbox where count > 0: CountBadge(count: count, isProminent: true)
            case .attention where count > 0: CountBadge(count: count, isProminent: false)
            case .inbox, .attention: EmptyView()
            case .plain:
                Text(count, format: .number)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(count > 0 ? L10n.format("%@，%@ 条", String(describing: title), String(describing: count)) : L10n.format("%@，空", String(describing: title)))
    }
}

private struct CountBadge: View {
    let count: Int
    let isProminent: Bool

    var body: some View {
        Text(count, format: .number)
            .font(.caption.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(isProminent ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
            .padding(.horizontal, Metric.gap4)
            .frame(minWidth: Metric.sidebarBadgeSize, minHeight: Metric.sidebarBadgeSize)
            .background(
                Capsule().fill(isProminent ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary))
            )
    }
}

// MARK: - Preconditions

private struct PreconditionBanner: View {
    let title: String
    let detail: String
    var actionTitle: String?
    var isProminent = false
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Metric.gap12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .imageScale(.large)
                    .filledGlyph(.orange)
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).font(.body.weight(.semibold))
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Metric.gap12)
                button
            }
            .padding(.horizontal, Metric.tableInset)
            .padding(.vertical, Metric.gap12)
            // The banner's ground is the warning colour at a fill weight, so the sentence
            // itself can stay `labelColor` and still pass at 13pt.
            .background(Color.orange.opacity(0.12))
            Divider()
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var button: some View {
        if let actionTitle, let action {
            if isProminent {
                Button(actionTitle, action: action).buttonStyle(.borderedProminent)
            } else {
                Button(actionTitle, action: action).buttonStyle(.bordered)
            }
        }
    }
}

// MARK: - Empty states

/// The empty state's job is to teach the only two gestures this product has, so it holds key
/// caps rather than an illustration.
private struct EmptyRecords: View {
    var bindings: HotKeyBindings = .shared

    var body: some View {
        VStack(spacing: Metric.gap16) {
            Text(L10n.tr("还没有润色记录")).font(.title3.weight(.semibold))
            Text(L10n.tr("在任何应用的输入区选中文字，按下快捷键。\n达意会就地改写，并保留一次专用撤回。"))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            VStack(alignment: .leading, spacing: Metric.gap8) {
                // Both are rebindable in Settings ▸ 通用. An empty state that teaches a
                // combination the person already changed teaches the wrong gesture.
                ForEach(HotKeyBindings.Role.allCases) { role in
                    hint(bindings.binding(for: role).display, role.title)
                }
            }
            Text(L10n.tr("记录保存在本机，下次启动自动恢复。"))
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(Metric.gap20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func hint(_ shortcut: String, _ label: String) -> some View {
        HStack(spacing: Metric.gap8) {
            KeyCapRow(shortcut: shortcut)
            Text(label).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label)，\(shortcut)")
    }
}

/// In place, compact, no illustration — and always a way back out of the filter that emptied
/// the table.
private struct NoMatches: View {
    let store: ActivityStore
    let filterTitle: String

    var body: some View {
        VStack(spacing: Metric.gap12) {
            if store.query.isEmpty {
                Text(L10n.format("「%@」里没有记录", String(describing: filterTitle))).font(.body.weight(.medium))
                Text(L10n.tr("这份清单现在是空的，其他记录仍在。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button(L10n.tr("查看全部活动")) { store.filter = .all }
            } else {
                Text(L10n.format("没有匹配「%@」的记录", String(describing: store.query))).font(.body.weight(.medium))
                Text(L10n.tr("搜索范围是原文与润色结果，正文清除后不再可搜。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button(L10n.tr("清除搜索")) { store.query = "" }
            }
        }
        .multilineTextAlignment(.center)
        .padding(Metric.gap20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Search

/// The toolbar's search field, in AppKit because ⌘F has to be able to move the keyboard into
/// it: SwiftUI's `.searchable` field cannot be focused programmatically before macOS 15, and
/// a search box the keyboard cannot reach is a search box for the pointer only.
private struct RecordSearchField: NSViewRepresentable {
    @Binding var text: String
    /// Any change to this value asks for first responder. The value itself means nothing.
    var focusToken: Int
    /// Raised while the keyboard is in the field, so the bare ⌫ and ↩ menu equivalents can
    /// disable themselves and let the keystroke reach the text.
    @Binding var isEditing: Bool
    var prompt: String
    /// Called for a click anywhere in this window that is not inside the field. A toolbar
    /// button does not take first responder — AppKit buttons refuse it unless Full Keyboard
    /// Access is on — so `controlTextDidEndEditing` never fires for one, and without this the
    /// box stayed open under a pointer that had plainly moved on to 排序 or 检查器.
    var onClickOutside: () -> Void

    func makeNSView(context: Context) -> FocusReportingSearchField {
        let field = FocusReportingSearchField()
        field.delegate = context.coordinator
        field.placeholderString = prompt
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = false
        field.onFocus = { [weak coordinator = context.coordinator] in coordinator?.report(true) }
        context.coordinator.watchClicksOutside(of: field)
        context.coordinator.focusToken = focusToken
        // The field is built only when somebody asks for it — ⌘F, or a click on the icon —
        // so it takes the keyboard as it appears. `makeNSView` runs before the view is in a
        // window, so the request waits for the next turn.
        DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        return field
    }

    func updateNSView(_ field: FocusReportingSearchField, context: Context) {
        if field.stringValue != text { field.stringValue = text }
        guard context.coordinator.focusToken != focusToken else { return }
        context.coordinator.focusToken = focusToken
        field.window?.makeFirstResponder(field)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, isEditing: $isEditing, clickedOutside: onClickOutside)
    }

    static func dismantleNSView(_ field: FocusReportingSearchField, coordinator: Coordinator) {
        coordinator.stopWatchingClicksOutside()
        // Hand the keyboard back on the way out. Removing a focused field leaves AppKit
        // looking for the next responder and it settles on the toolbar, which then draws a
        // focus ring around all three items — a wide blue capsule that outlives the field by
        // half a second and belongs to nothing the user can see.
        guard let window = field.window else { return }
        let editing = window.firstResponder
        if editing === field || (editing as? NSView)?.isDescendant(of: field) == true {
            window.makeFirstResponder(nil)
        }
    }

    @MainActor final class Coordinator: NSObject, NSSearchFieldDelegate {
        var focusToken = 0
        private let text: Binding<String>
        private let isEditing: Binding<Bool>
        private let clickedOutside: () -> Void
        private var monitor: Any?

        init(text: Binding<String>, isEditing: Binding<Bool>, clickedOutside: @escaping () -> Void) {
            self.text = text
            self.isEditing = isEditing
            self.clickedOutside = clickedOutside
        }

        /// Local, so it only sees this application's clicks, and it passes every event through
        /// untouched: the click still reaches whatever it was aimed at.
        func watchClicksOutside(of field: NSSearchField) {
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self, weak field] event in
                MainActor.assumeIsolated {
                    guard let self, let field, let window = field.window, event.window === window else { return }
                    let point = field.convert(event.locationInWindow, from: nil)
                    guard !field.bounds.contains(point) else { return }
                    self.clickedOutside()
                }
                return event
            }
        }

        func stopWatchingClicksOutside() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            text.wrappedValue = field.stringValue
        }

        /// The field editor is what actually resigns, and the control is not told; the end of
        /// an edit session is.
        func controlTextDidEndEditing(_ notification: Notification) { report(false) }

        /// ⌘F takes first responder from inside `updateNSView`, which is a SwiftUI update, so
        /// the flag is written on the next turn rather than in the middle of one.
        func report(_ editing: Bool) {
            guard isEditing.wrappedValue != editing else { return }
            Task { @MainActor in
                guard self.isEditing.wrappedValue != editing else { return }
                self.isEditing.wrappedValue = editing
            }
        }
    }
}

/// `NSSearchField` says when an edit ends through its delegate, but not when the keyboard
/// arrives — a click focuses the field editor without beginning an edit session.
private final class FocusReportingSearchField: NSSearchField {
    var onFocus: (@MainActor () -> Void)?

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocus?() }
        return accepted
    }
}
