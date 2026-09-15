import PolishCore
import AppKit
import SwiftUI

/// Owns a public NSTableView instead of modifying SwiftUI.Table's private backing views.
/// AppKit supplies view reuse, native scrolling, selection, column resizing and sorting.
struct NativeRecordTable: NSViewRepresentable {
    let items: [ActivityItem]
    @Binding var selection: Set<UUID>
    @Binding var sort: ActivitySort
    let perform: (ActivityAction, ActivityItem) -> Void
    let delete: (Set<UUID>) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        let table = RecordTableView()
        table.style = .inset
        table.rowSizeStyle = .custom
        // The existing design has 28pt content and 4pt vertical padding at each edge.
        table.rowHeight = Metric.rowHeight + Metric.gap8
        table.usesAutomaticRowHeights = false
        table.intercellSpacing.height = 0
        table.gridStyleMask = .solidHorizontalGridLineMask
        table.gridColor = .separatorColor
        table.backgroundColor = .textBackgroundColor
        table.allowsMultipleSelection = true
        table.allowsColumnReordering = false
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        for column in Column.allCases {
            let native = NSTableColumn(identifier: column.identifier)
            native.title = column.title
            native.width = column.width
            native.minWidth = column.width
            native.maxWidth = column.maximumWidth
            native.resizingMask = column == .original ? [.autoresizingMask, .userResizingMask] : .userResizingMask
            if column == .original { native.minWidth = Metric.textColumnMinWidth }
            if let field = column.sortField {
                native.sortDescriptorPrototype = NSSortDescriptor(key: field.rawValue, ascending: field != .time)
            }
            native.headerCell.alignment = column.alignment
            table.addTableColumn(native)
        }
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.openRow(_:))
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = context.coordinator
        table.menu = menu
        scroll.documentView = table
        context.coordinator.table = table
        context.coordinator.update(self)
        return scroll
    }

    func updateNSView(_ view: NSScrollView, context: Context) { context.coordinator.update(self) }

    static func dismantleNSView(_ view: NSScrollView, coordinator: Coordinator) {
        coordinator.table?.delegate = nil
        coordinator.table?.dataSource = nil
        coordinator.table?.menu?.delegate = nil
    }

    enum Column: String, CaseIterable {
        case state, app, original, model, duration, time
        var identifier: NSUserInterfaceItemIdentifier { .init(rawValue) }
        var title: String {
            switch self {
            case .state: ""
            case .app: L10n.tr("来源")
            case .original: L10n.tr("原文")
            case .model: L10n.tr("模型")
            case .duration: L10n.tr("耗时")
            case .time: L10n.tr("时间")
            }
        }
        var width: CGFloat {
            switch self {
            case .state: Metric.statusColumnWidth
            case .app: Metric.appColumnWidth
            case .original: Metric.textColumnWidth
            case .model: Metric.modelColumnWidth
            case .duration: Metric.durationColumnWidth
            case .time: Metric.timeColumnWidth
            }
        }
        var maximumWidth: CGFloat {
            switch self {
            case .app: Metric.appColumnMaxWidth
            case .original: .greatestFiniteMagnitude
            case .model: Metric.modelColumnMaxWidth
            default: width
            }
        }
        var alignment: NSTextAlignment { self == .duration || self == .time ? .right : .left }
        var sortField: ActivitySort.Field? { ActivitySort.Field(rawValue: rawValue) }
    }

    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        private var parent: NativeRecordTable
        private(set) var rows: [ActivityItem] = []
        weak var table: NSTableView?
        private var updating = false

        init(_ parent: NativeRecordTable) { self.parent = parent }

        func update(_ parent: NativeRecordTable) {
            self.parent = parent
            guard let table else { return }
            updating = true
            defer { updating = false }
            let previous = rows
            rows = parent.items
            if previous.map(\.id) != rows.map(\.id) {
                table.reloadData()
            } else {
                let changed = IndexSet(rows.indices.filter { rows[$0] != previous[$0] })
                if !changed.isEmpty {
                    table.reloadData(forRowIndexes: changed, columnIndexes: IndexSet(integersIn: 0..<Column.allCases.count))
                }
            }
            let selected = IndexSet(rows.indices.filter { parent.selection.contains(rows[$0].id) })
            if table.selectedRowIndexes != selected { table.selectRowIndexes(selected, byExtendingSelection: false) }
            let descriptor = NSSortDescriptor(key: parent.sort.field.rawValue, ascending: parent.sort.ascending)
            if table.sortDescriptors != [descriptor] { table.sortDescriptors = [descriptor] }
        }

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn, let column = Column(rawValue: tableColumn.identifier.rawValue) else { return nil }
            let item = rows[row]
            if column == .state {
                let cell = tableView.makeView(withIdentifier: column.identifier, owner: nil) as? ActivityStateCell
                    ?? ActivityStateCell()
                cell.identifier = column.identifier
                cell.configure(item)
                return cell
            }
            let cell = tableView.makeView(withIdentifier: column.identifier, owner: nil) as? ActivityTextCell
                ?? ActivityTextCell()
            cell.identifier = column.identifier
            cell.configure(item, column: column) { [weak self] action in self?.parent.perform(action, item) }
            return cell
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !updating, let table else { return }
            parent.selection = Set(table.selectedRowIndexes.map { rows[$0].id })
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard !updating, let descriptor = tableView.sortDescriptors.first,
                  let key = descriptor.key, let field = ActivitySort.Field(rawValue: key) else { return }
            parent.sort = ActivitySort(field: field, ascending: descriptor.ascending)
        }

        @objc func openRow(_ sender: NSTableView) {
            guard rows.indices.contains(sender.clickedRow) else { return }
            let item = rows[sender.clickedRow]
            if let action = item.actions.first(where: { $0 == .jumpBack })
                ?? item.actions.first(where: { $0 == .returnToContext }) {
                parent.perform(action, item)
            }
        }

        private struct MenuAction {
            let ids: Set<UUID>
            let action: ActivityAction?
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let table else { return }
            let ids: Set<UUID>
            if rows.indices.contains(table.clickedRow), !table.selectedRowIndexes.contains(table.clickedRow) {
                ids = [rows[table.clickedRow].id]
            } else {
                ids = Set(table.selectedRowIndexes.map { rows[$0].id })
            }
            if ids.count == 1, let item = rows.first(where: { ids.contains($0.id) }) {
                for action in item.actions {
                    let entry = NSMenuItem(title: action.title(for: item), action: #selector(runMenu(_:)), keyEquivalent: "")
                    entry.target = self
                    entry.representedObject = MenuAction(ids: ids, action: action)
                    menu.addItem(entry)
                }
                if !item.actions.isEmpty { menu.addItem(.separator()) }
            }
            let entry = NSMenuItem(title: ids.count > 1 ? L10n.format("删除 %@ 条记录", String(describing: ids.count)) : L10n.tr("删除记录"),
                                   action: #selector(runMenu(_:)), keyEquivalent: "")
            entry.target = self
            entry.isEnabled = !ids.isEmpty
            entry.representedObject = MenuAction(ids: ids, action: nil)
            menu.addItem(entry)
        }

        @objc private func runMenu(_ sender: NSMenuItem) {
            guard let command = sender.representedObject as? MenuAction else { return }
            if let action = command.action, let item = rows.first(where: { command.ids.contains($0.id) }) {
                parent.perform(action, item)
            } else if command.action == nil {
                parent.delete(command.ids)
            }
        }
    }
}

/// Native labels are reused as rows enter the viewport; scrolling never builds SwiftUI cells.
@MainActor final class ActivityTextCell: NSTableCellView {
    private let label = NSTextField(labelWithString: "")
    private var ordinaryColor = NSColor.labelColor
    private var actions: [ActivityAction] = []
    private var perform: ((ActivityAction) -> Void)?
    private var buttons: [NSButton] = []
    private var hovered = false
    private var tracking: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        // Modern AppKit leaves views unclipped by default; hover must stay within this cell.
        clipsToBounds = true
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        textField = label
        addSubview(label)
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ item: ActivityItem, column: NativeRecordTable.Column,
                   perform: @escaping (ActivityAction) -> Void) {
        self.perform = perform
        toolTip = column == .app ? item.website.map { "\($0.host) · \(item.targetLabel)" } ?? item.targetLabel : nil
        label.alignment = column.alignment
        label.font = column == .model || column == .duration
            ? .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular) : .systemFont(ofSize: NSFont.systemFontSize)
        switch column {
        case .app: label.stringValue = item.sourceLabel; ordinaryColor = .labelColor
        case .original:
            label.stringValue = item.previewText
            ordinaryColor = item.textCleared ? .tertiaryLabelColor : .labelColor
            if item.textCleared { label.font = NSFontManager.shared.convert(label.font!, toHaveTrait: .italicFontMask) }
        case .model: label.stringValue = item.modelText; ordinaryColor = item.model == nil ? .tertiaryLabelColor : .secondaryLabelColor
        case .duration: label.stringValue = item.durationText; ordinaryColor = item.duration == nil ? .tertiaryLabelColor : .secondaryLabelColor
        case .time: label.stringValue = item.timeText; ordinaryColor = .secondaryLabelColor
        case .state: break
        }
        actions = column == .original ? item.actions.filter { $0 == .copyResult || $0 == .returnToContext } : []
        while buttons.count < actions.count {
            let button = NSButton(image: NSImage(), target: self, action: #selector(runButton(_:)))
            button.bezelStyle = .inline
            button.isBordered = false
            button.tag = buttons.count
            button.wantsLayer = true
            button.layer?.cornerRadius = Metric.radiusBadge
            button.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
            buttons.append(button)
            addSubview(button)
        }
        for (index, action) in actions.enumerated() {
            buttons[index].image = NSImage(systemSymbolName: action.symbol, accessibilityDescription: action.title(for: item))
            buttons[index].toolTip = action.title(for: item)
            buttons[index].setAccessibilityLabel(action.title(for: item))
        }
        refreshAppearance()
        updateTrackingAreas()
    }

    override var backgroundStyle: NSView.BackgroundStyle { didSet { refreshAppearance() } }

    private func refreshAppearance() {
        let selected = backgroundStyle == .emphasized
        label.textColor = selected ? .alternateSelectedControlTextColor : ordinaryColor
        for (index, button) in buttons.enumerated() {
            button.isHidden = !hovered || selected || index >= actions.count
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let visible = buttons.filter { !$0.isHidden }
        let occupied = CGFloat(visible.count) * (Metric.gap20 + Metric.gap4)
        label.frame = NSRect(x: 0, y: (bounds.height - 18) / 2,
                             width: max(0, bounds.width - occupied), height: 18)
        for (index, button) in visible.enumerated() {
            button.frame = NSRect(x: bounds.width - CGFloat(visible.count - index) * (Metric.gap20 + Metric.gap4),
                                  y: (bounds.height - Metric.gap20) / 2, width: Metric.gap20, height: Metric.gap20)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if actions.isEmpty {
            if let tracking { removeTrackingArea(tracking); self.tracking = nil }
        } else if tracking == nil {
            // AppKit keeps this area aligned with visibleRect as the table scrolls.
            let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
            addTrackingArea(area)
            tracking = area
        }
        updateHover()
    }
    private func updateHover() {
        // A scrolled or reused cell can move away without receiving mouseExited.
        // Reconcile with current geometry, including when an old event is queued.
        let inside: Bool
        if let window, window.isKeyWindow, !actions.isEmpty, !isHiddenOrHasHiddenAncestor {
            inside = visibleRect.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
        } else {
            inside = false
        }
        guard hovered != inside else { return }
        hovered = inside
        refreshAppearance()
    }
    override func mouseEntered(with event: NSEvent) { updateHover() }
    override func mouseExited(with event: NSEvent) { updateHover() }
    @objc private func runButton(_ button: NSButton) { perform?(actions[button.tag]) }
}

@MainActor private final class ActivityStateCell: NSTableCellView {
    private let glyph = NSImageView()
    private let spinner = NSProgressIndicator()
    private var state = ActivityState.applied

    override init(frame: NSRect) {
        super.init(frame: frame)
        imageView = glyph
        addSubview(glyph)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        addSubview(spinner)
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ item: ActivityItem) {
        state = item.state
        setAccessibilityLabel(item.rowSummary)
        let running = state == .running || state == .applying
        glyph.isHidden = running
        if running { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        refreshAppearance()
    }

    override var backgroundStyle: NSView.BackgroundStyle { didSet { refreshAppearance() } }

    private func refreshAppearance() {
        let selected = backgroundStyle == .emphasized
        let tint = selected ? NSColor.white : state.tint.map { NSColor($0) } ?? .labelColor
        let background = selected ? NSColor.selectedContentBackgroundColor : .textBackgroundColor
        glyph.image = NSImage(systemSymbolName: state.symbol, accessibilityDescription: state.name)?
            .withSymbolConfiguration(.init(paletteColors: state.hasMarkLayer ? [background, tint] : [tint]))
    }

    override func layout() {
        super.layout()
        glyph.frame = NSRect(x: 0, y: (bounds.height - 14) / 2, width: 14, height: 14)
        spinner.frame = NSRect(x: 0, y: (bounds.height - 16) / 2, width: 16, height: 16)
    }
}

/// AppKit answers a table's accessibility children by creating a cell view for every row of
/// every column (`NSTableViewCellMockElement` → `viewAtColumn:row:makeIfNecessary:`). With a
/// few hundred records that is more than a thousand views built on the main thread per query,
/// measured at 2.5 s for 189 rows, and an assistive client that re-reads the window after each
/// change keeps the app beachballing for as long as it polls. Only the rows on screen are
/// answered. Scrolling brings the rest into reach, which is how VoiceOver walks any long list.
@MainActor final class RecordTableView: NSTableView {
    private var visibleRowViews: [Any] {
        let range = rows(in: visibleRect)
        guard range.length > 0 else { return [] }
        return (range.location..<NSMaxRange(range)).compactMap { rowView(atRow: $0, makeIfNecessary: false) }
    }

    @objc func accessibilityRows() -> [Any]? { visibleRowViews }

    @objc func accessibilityVisibleRows() -> [Any]? { visibleRowViews }

    @objc func accessibilitySelectedRows() -> [Any]? {
        let visible = rows(in: visibleRect)
        return selectedRowIndexes.filter { visible.contains($0) }.compactMap { rowView(atRow: $0, makeIfNecessary: false) }
    }

    override func accessibilityChildren() -> [Any]? {
        var children: [Any] = []
        if let header = headerView { children.append(header) }
        children.append(contentsOf: visibleRowViews)
        return children
    }
}
