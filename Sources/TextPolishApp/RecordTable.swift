import SwiftUI

/// SwiftUI owns the window and commands; AppKit owns the table, its cells and scrolling.
struct RecordTable: View {
    @Bindable private var store: ActivityStore
    @Environment(\.openSettings) private var openSettings

    init(store: ActivityStore) { _store = Bindable(store) }

    var body: some View {
        NativeRecordTable(items: store.visibleItems, selection: $store.selection, sort: $store.sortOrder,
                          perform: run, delete: { store.delete($0) })
    }

    private func run(_ action: ActivityAction, on item: ActivityItem) {
        if !store.perform(action, on: item) {
            SettingsRoute.shared.show(.model)
            openSettings()
        }
    }
}
