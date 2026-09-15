import AppKit
import Foundation
import Observation
import PolishCore
import PolishStore
import SwiftUI

/// How the table is ordered. Named rather than nested so it does not shadow Foundation's
/// `SortOrder` inside the store.
struct ActivitySort: Hashable, Sendable {
    enum Field: String, Hashable, CaseIterable, Sendable { case state, app, model, duration, time }
    var field: Field
    var ascending: Bool

    /// Newest first. Time is the only column whose default direction is descending, because
    /// the row a person came for is almost always the one that just happened.
    static let newestFirst = ActivitySort(field: .time, ascending: false)
}

/// The activity window's only data source. Jobs and records are merged, de-duplicated and
/// projected into `ActivityItem` here, so no view ever sees a `PolishJob` or a `PolishRecord`.
@MainActor @Observable
final class ActivityStore {
    enum Filter: Hashable {
        case pending, unfinished, all
        case app(String)
        case website(String)
    }

    var query = ""
    var selection: Set<UUID> = []
    var sortOrder = ActivitySort.newestFirst

    /// 待应用 is the inbox, so it selects itself while it has something in it — and only
    /// until the person picks something else, which is what the stored override records.
    var filter: Filter {
        get { chosenFilter ?? (pendingCount > 0 ? .pending : .all) }
        set { chosenFilter = newValue }
    }

    private var chosenFilter: Filter?

    /// The waiting results, read straight off the job list rather than off `items`: only a
    /// live job can be blocked-and-rescuable, and this is consulted on every filter read.
    private var liveBlocked: [PolishJob] {
        model?.jobs.jobs.filter {
            ActivityState(compute: $0.computeState, application: $0.applicationState) == .blocked
        } ?? []
    }
    @ObservationIgnored private weak var model: AppModel?

    /// `AppModel` owns this store and this store reads back through it, so the link is made
    /// after both exist and is weak in this direction.
    func attach(_ model: AppModel) { self.model = model }

    // MARK: - Items

    /// What the projection was built from. Nothing here is compared field by field in the
    /// common case: two unchanged arrays share their storage, so `==` settles on the fast
    /// path and the merge below is skipped.
    private struct ItemSource: Equatable {
        let records: [PolishRecord]
        let jobs: [JobFingerprint]
        let elapsed: [UUID: Double]
    }

    /// `PolishJob` is not `Equatable` and belongs to `PolishCore`, so its mutable half is
    /// copied out instead. Those five fields are everything a projected row can show.
    private struct JobFingerprint: Equatable {
        let id: UUID
        let model: String
        let compute: ComputeState
        let application: ApplicationState
        let result: String?
        let message: String?

        init(_ job: PolishJob) {
            id = job.id
            model = job.model
            compute = job.computeState
            application = job.applicationState
            result = job.result
            message = job.message
        }
    }

    /// The merge is a dictionary, a set, n projections and a sort, and one body pass reads it
    /// from a dozen places — the subtitle, the table, three sidebar counts, the inspector, two
    /// menu commands. While a job runs, `runningElapsed` rewrites once a second and
    /// invalidates all of them at once. Doing the work once per input change is what keeps
    /// that second linear instead of quadratic in readers.
    @ObservationIgnored private var itemCache: (source: ItemSource, generation: Int, items: [ActivityItem])?
    /// The filtered, sorted list keys off the generation above rather than off the rows, so a
    /// second reader in the same pass compares one integer and three small values.
    /// Grouping and sorting the whole log per read is affordable once and not per frame.
    @ObservationIgnored private var appCache: (generation: Int, apps: [(label: String, count: Int)])?
    @ObservationIgnored private var websiteCache: (generation: Int, sites: [(host: String, count: Int)])?
    @ObservationIgnored private var listCache: (generation: Int, filter: Filter, query: String,
                                                sort: ActivitySort, items: [ActivityItem])?
    @ObservationIgnored private var generation = 0

    /// Live jobs win over their stored rows: the record is a snapshot of the same attempt,
    /// written on every state change, and only the job still has a context to act on.
    var items: [ActivityItem] {
        guard let model else { return [] }
        // Read through the model every time even on a hit: this is where the observation
        // registration is made, and skipping it would leave readers unsubscribed.
        let source = ItemSource(records: model.history.records,
                                jobs: model.jobs.jobs.map(JobFingerprint.init),
                                elapsed: model.runningElapsed)
        if let itemCache, itemCache.source == source { return itemCache.items }

        let records = source.records
        let stored = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let jobs = model.jobs.jobs
        let live = Set(jobs.map(\.id))
        var merged = jobs.map {
            ActivityItem(job: $0, storedAs: stored[$0.id], elapsed: source.elapsed[$0.id])
        }
        merged += records.lazy.filter { !live.contains($0.id) }.map {
            ActivityItem(record: $0, elapsed: source.elapsed[$0.id])
        }
        // Newest first, once. Every consumer that shows a subset — the menu bar's inbox, the
        // table before a column is clicked — inherits that order rather than sorting again.
        merged.sort { $0.createdAt > $1.createdAt }
        generation &+= 1
        itemCache = (source, generation, merged)
        return merged
    }

    var visibleItems: [ActivityItem] {
        // Both the filter and the query are read once: the filter getter consults the pending
        // count, and evaluating that per row would walk the whole list per row.
        let rows = items
        let stamp = itemCache?.generation ?? 0
        let current = filter, search = query, order = sortOrder
        if let listCache, listCache.generation == stamp, listCache.filter == current,
           listCache.query == search, listCache.sort == order {
            return listCache.items
        }
        let visible = sorted(rows.filter { matches(current, $0) && $0.matches(search) })
        listCache = (stamp, current, search, order, visible)
        return visible
    }

    /// The inspector shows one record. Two selected rows are a delete target, not a subject.
    var selected: ActivityItem? {
        guard selection.count == 1, let id = selection.first else { return nil }
        return items.first { $0.id == id }
    }

    // MARK: - Sidebar

    /// Only results that are still in memory can be rescued, so only they are counted here.
    /// A `blocked` row read back from disk lost its context when the app quit; it is history.
    var pendingCount: Int { liveBlocked.count }
    var unfinishedCount: Int { items.filter { $0.state == .failed || $0.state == .uncertain }.count }
    var totalCount: Int { items.count }

    /// Per-application groups, most-used first: the mental index is "the thing I wrote in
    /// Claude", not a timestamp.
    var apps: [(label: String, count: Int)] {
        let rows = items
        let stamp = itemCache?.generation ?? 0
        if let appCache, appCache.generation == stamp { return appCache.apps }
        let counted: [(label: String, count: Int)] = Dictionary(grouping: rows, by: \.targetLabel)
            .map { (label: $0.key, count: $0.value.count) }
        let grouped = counted.sorted { first, second in
            if first.count != second.count { return first.count > second.count }
            return first.label.localizedStandardCompare(second.label) == .orderedAscending
        }
        appCache = (generation: stamp, apps: grouped)
        return grouped
    }

    var isEmpty: Bool { items.isEmpty }
    var websites: [(host: String, count: Int)] {
        let rows = items
        let stamp = itemCache?.generation ?? 0
        if let websiteCache, websiteCache.generation == stamp { return websiteCache.sites }
        let counted = Dictionary(grouping: rows.compactMap(\.website), by: \.host)
            .map { (host: $0.key, count: $0.value.count) }
            .sorted { first, second in
                if first.count != second.count { return first.count > second.count }
                return first.host.localizedStandardCompare(second.host) == .orderedAscending
            }
        websiteCache = (stamp, counted)
        return counted
    }
    /// There are records, but none of them match — a different empty state, with a way out.
    var hasNoMatches: Bool { !items.isEmpty && visibleItems.isEmpty }

    // MARK: - Actions

    /// The reason this window exists. Activation comes first and does not depend on the
    /// context still being valid: getting the person back in front of the field is the point,
    /// and restoring the selection is the bonus.
    func jumpBack(_ item: ActivityItem) {
        Self.runningApplication(named: item.targetLabel)?.activate()
        guard item.isLive else { return }
        model?.jobs.returnToContext(item.id)
    }

    func returnToContext(_ item: ActivityItem) {
        guard item.isLive else { return }
        model?.jobs.returnToContext(item.id)
    }

    func copyResult(_ item: ActivityItem) {
        guard let result = item.resultText, !result.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(result, forType: .string)
    }

    func undo(_ item: ActivityItem) {
        guard item.isLive else { return }
        model?.jobs.undo(item.id)
    }

    /// `PolishJobs` has no re-run entry point — it holds the target handle privately and a
    /// window has no target of its own to capture. The honest retry is therefore to put the
    /// caret back on the original selection so the next ⌃⌥P sends exactly the same text.
    func retry(_ item: ActivityItem) {
        guard item.isLive else { return }
        Self.runningApplication(named: item.targetLabel)?.activate()
        model?.jobs.returnToContext(item.id)
    }

    /// Runs the action a row offered. `.checkModel` opens the Settings scene, which only a
    /// view can do, so it is reported back rather than swallowed.
    @discardableResult
    func perform(_ action: ActivityAction, on item: ActivityItem) -> Bool {
        switch action {
        case .jumpBack: jumpBack(item)
        case .copyResult: copyResult(item)
        case .returnToContext: returnToContext(item)
        case .undo: undo(item)
        case .retry: retry(item)
        case .checkModel: return false
        }
        return true
    }

    /// Deletes from both halves: an id may name a live job, a stored row, or both.
    func delete(_ ids: some Collection<UUID>) {
        guard let model else { return }
        for id in ids {
            model.jobs.dismiss(id)
            model.history.remove(id)
        }
        selection.subtract(Set(ids))
    }

    func clearAll() {
        guard let model else { return }
        for job in model.jobs.jobs { model.jobs.dismiss(job.id) }
        model.history.clear()
        selection = []
    }

    // MARK: - Derivation

    private func matches(_ filter: Filter, _ item: ActivityItem) -> Bool {
        switch filter {
        case .all: true
        case .pending: item.state == .blocked && item.isLive
        case .unfinished: item.state == .failed || item.state == .uncertain
        case .app(let label): item.targetLabel == label
        case .website(let host): item.website?.host == host
        }
    }

    private func sorted(_ items: [ActivityItem]) -> [ActivityItem] {
        items.sorted { first, second in
            switch compare(first, second) {
            case .orderedAscending: sortOrder.ascending
            case .orderedDescending: !sortOrder.ascending
            // Equal under the chosen column and equal in time: order by id so the row does
            // not swap places with its neighbour every time the table redraws.
            case .orderedSame: first.id.uuidString < second.id.uuidString
            }
        }
    }

    /// Compares two rows by the chosen column, falling back to time — the only value no two
    /// records share, and the reason it is also the default column.
    private func compare(_ first: ActivityItem, _ second: ActivityItem) -> ComparisonResult {
        switch sortOrder.field {
        case .state where first.state != second.state:
            return first.state.sortRank < second.state.sortRank ? .orderedAscending : .orderedDescending
        case .app where first.sourceLabel != second.sourceLabel:
            return first.sourceLabel.localizedStandardCompare(second.sourceLabel)
        case .model where first.modelText != second.modelText:
            return first.modelText.localizedStandardCompare(second.modelText)
        case .duration:
            // A row with no measured duration sorts as zero rather than dropping out.
            let left = first.duration ?? 0, right = second.duration ?? 0
            if left != right { return left < right ? .orderedAscending : .orderedDescending }
            return byTime(first, second)
        default:
            return byTime(first, second)
        }
    }

    private func byTime(_ first: ActivityItem, _ second: ActivityItem) -> ComparisonResult {
        guard first.createdAt != second.createdAt else { return .orderedSame }
        return first.createdAt < second.createdAt ? .orderedAscending : .orderedDescending
    }

    private static func runningApplication(named label: String) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first { $0.localizedName == label }
    }
}
