import AppKit
import Observation
import PolishCore
import PolishStore
import SwiftUI
import Testing
@testable import TextPolishApp

@Suite @MainActor
struct NativeRecordTableTests {
    private final class PointerWindow: NSWindow {
        var pointer = NSPoint(x: 50, y: 18)
        override var mouseLocationOutsideOfEventStream: NSPoint { pointer }
        override var isKeyWindow: Bool { true }
    }

    @Test func scrollingAndReuseReconcileHoverWithoutAnExitEvent() throws {
        _ = NSApplication.shared
        let window = PointerWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                                   styleMask: [.borderless], backing: .buffered, defer: false)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        window.contentView = content
        defer { window.contentView = nil }
        let cell = ActivityTextCell(frame: NSRect(x: 0, y: 0, width: 300, height: 36))
        content.addSubview(cell)
        let items = State().items
        cell.configure(items[0], column: .original, perform: { _ in })
        let event = try #require(NSEvent.enterExitEvent(with: .mouseEntered, location: window.pointer,
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
        cell.mouseEntered(with: event)
        let button = try #require(cell.subviews.compactMap { $0 as? NSButton }.first)
        #expect(!button.isHidden)

        // Scrolling moves a hovered cell away without moving the pointer or delivering an exit.
        cell.frame.origin.y = 72
        cell.updateTrackingAreas()
        #expect(cell.visibleRect == cell.bounds)
        #expect(button.isHidden)
        cell.layoutSubtreeIfNeeded()
        #expect(cell.textField?.frame.width == cell.bounds.width)

        // The same view returns under the stationary pointer and is then reused elsewhere.
        cell.frame.origin.y = 0
        cell.updateTrackingAreas()
        #expect(!button.isHidden)
        cell.frame.origin.y = 108
        cell.configure(items[1], column: .original, perform: { _ in })
        #expect(button.isHidden)
        cell.mouseEntered(with: event) // A queued event from the old tracking geometry.
        #expect(button.isHidden)
    }

    @Observable final class State {
        var items = (0..<500).map { index in
            ActivityItem(record: PolishRecord(targetLabel: "Notes", model: "test-model",
                originalText: "草稿 \(index)", resultText: "结果 \(index)", outcome: .applied))
        }
        var selection: Set<UUID> = []
        var sort = ActivitySort.newestFirst
        var performed: [ActivityAction] = []
        var deleted: Set<UUID> = []
    }

    private struct Fixture: View {
        @Bindable var state: State
        var body: some View {
            NativeRecordTable(items: state.items, selection: $state.selection, sort: $state.sort,
                              perform: { action, _ in state.performed.append(action) },
                              delete: { state.deleted = $0 })
        }
    }

    private func table(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        return view.subviews.lazy.compactMap { table(in: $0) }.first
    }

    private func settle(_ view: NSView) async {
        view.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(50))
        view.layoutSubtreeIfNeeded()
    }

    @Test(arguments: [false, true])
    func tableFitsInsideNavigationWindow(showingDetail: Bool) async throws {
        _ = NSApplication.shared
        let state = State()
        let host = NSHostingView(rootView: NavigationSplitView {
            List { Text("Awaiting Apply"); Text("Unfinished"); Text("All Activity") }
                .navigationSplitViewColumnWidth(198)
        } detail: {
            Fixture(state: state)
                .inspector(isPresented: .constant(true)) {
                    Group {
                        if showingDetail {
                            RecordInspector(store: ActivityStore()).detail(state.items[0])
                        } else {
                            RecordInspector(store: ActivityStore())
                        }
                    }
                    .inspectorColumnWidth(min: 260, ideal: 300, max: 420)
                }
                .navigationTitle("All Activity")
                .toolbar { Button("Search") {} }
        }.frame(minWidth: 720, minHeight: 420))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 620),
                              styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        await settle(host)
        let table = try #require(self.table(in: host))
        let scroll = try #require(table.enclosingScrollView)
        let header = try #require(table.headerView)
        for size in [NSSize(width: 1000, height: 620), NSSize(width: 1260, height: 420),
                     NSSize(width: 1260, height: 800)] {
            window.setContentSize(size)
            await settle(host)
            let viewport = scroll.convert(scroll.bounds, to: host)
            let headerFrame = header.convert(header.bounds, to: host)
            // The inspector's wrapped placeholder/footer must not increase the split view's
            // minimum height and move the sidebar/table above the window's toolbar.
            #expect(viewport.minY >= host.safeAreaInsets.top)
            #expect(viewport.maxY <= host.bounds.maxY)
            #expect(headerFrame.minY >= host.safeAreaInsets.top)
            #expect(headerFrame.maxY <= host.bounds.maxY)
        }
    }

    @Test func scrollingSelectionSortingAndFilteringKeepNativeRowGeometry() async throws {
        _ = NSApplication.shared
        let state = State()
        let host = NSHostingView(rootView: Fixture(state: state))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        await settle(host)
        let table = try #require(self.table(in: host))
        #expect(table.numberOfRows == 500)
        #expect(table.numberOfColumns == 6)
        #expect(!table.usesAutomaticRowHeights)
        #expect(table.rowHeight == 36)

        table.selectRowIndexes([3, 5], byExtendingSelection: false)
        await settle(host)
        #expect(state.selection == [state.items[3].id, state.items[5].id])
        #expect(!table.usesAutomaticRowHeights)
        table.sortDescriptors = [NSSortDescriptor(key: "app", ascending: true)]
        #expect(state.sort == ActivitySort(field: .app, ascending: true))
        table.scrollRowToVisible(499)
        await settle(host)
        #expect(table.rect(ofRow: 499).height == 36)

        let originalWidth = table.tableColumns[2].width
        let modelWidth = table.tableColumns[3].width
        host.frame.size.width += 200
        await settle(host)
        #expect(table.tableColumns[2].width > originalWidth)
        #expect(table.tableColumns[3].width == modelWidth)

        let keep = state.items[5]
        state.items = [keep]
        state.selection = [keep.id]
        await settle(host)
        #expect(table.numberOfRows == 1)
        #expect(table.selectedRowIndexes == [0])
        #expect(table.rect(ofRow: 0).height == 36)
        let cell = try #require(table.view(atColumn: 2, row: 0, makeIfNecessary: true) as? NSTableCellView)
        #expect(cell.textField?.stringValue == keep.previewText)

        let menu = try #require(table.menu)
        menu.delegate?.menuNeedsUpdate?(menu)
        #expect(menu.items.first?.title == L10n.tr("复制结果"))
        menu.performActionForItem(at: 0)
        #expect(state.performed == [.copyResult])
        menu.performActionForItem(at: menu.items.count - 1)
        #expect(state.deleted == [keep.id])
    }
}
