import AppKit
import Observation
import PolishCore
import PolishStore
import SwiftUI

/// Retention as a person chooses it — whole days and a row count — rather than as the
/// seconds `RetentionPolicy` stores. Keeping the chosen units is what lets the pickers come
/// back showing the same option that was picked.
struct RetentionChoice: Codable, Equatable, Sendable {
    /// Nil means no age limit.
    var maxAgeDays: Int?
    /// Nil means no count limit.
    var maxCount: Int?
    /// Nil keeps drafts for as long as the row lives; 0 clears them at the next purge.
    var textClearDays: Int?

    /// The same numbers `RetentionPolicy.standard` has always used, so an install that never
    /// opens this tab behaves exactly as it did.
    static let standard = RetentionChoice(maxAgeDays: 30, maxCount: 500, textClearDays: 7)

    static let ageOptions: [Int?] = [7, 30, 90, nil]
    static let countOptions: [Int?] = [100, 500, 2000, nil]
    static let textOptions: [Int?] = [0, 1, 7, 30, nil]

    var policy: RetentionPolicy {
        RetentionPolicy(maxAge: maxAgeDays.map { Double($0) * 86_400 },
                        maxCount: maxCount,
                        textMaxAge: textClearDays.map { Double($0) * 86_400 })
    }

    static func ageLabel(_ days: Int?) -> String { days.map { L10n.format("最长 %@ 天", String(describing: $0)) } ?? L10n.tr("不限时长") }
    static func countLabel(_ count: Int?) -> String { count.map { L10n.format("最多 %@ 条", String(describing: $0)) } ?? L10n.tr("不限条数") }
    static func textLabel(_ days: Int?) -> String {
        switch days {
        case .none: L10n.tr("不清除")
        case .some(0): L10n.tr("立即")
        case .some(let days): L10n.format("%@ 天后", String(describing: days))
        }
    }
}

/// What the database is allowed to keep, and the one place that changes it.
///
/// `AppModel` used to hard-code `RetentionPolicy.standard`. The policy now comes from the
/// preferences table, and changing it purges immediately: a retention setting that only takes
/// effect at the next launch is a promise about text that is still on disk.
@MainActor @Observable
final class RetentionSettings {
    static let shared = RetentionSettings()
    static let preferenceKey = "retention.policy"

    private(set) var choice = RetentionChoice.standard
    private(set) var lastPurge: PurgeReport?
    private(set) var failure: String?

    @ObservationIgnored private var preferences: (any PreferenceStore)?
    @ObservationIgnored private var records: (any RecordStore)?

    var policy: RetentionPolicy { choice.policy }

    /// Integration hook: `AppModel.openStorage()` calls this before `history.attach`, and
    /// passes `RetentionSettings.shared.policy` as that call's purge policy.
    func attach(preferences: any PreferenceStore, records: any RecordStore) async {
        self.preferences = preferences
        self.records = records
        guard let json = try? await preferences.value(forKey: Self.preferenceKey),
              let saved = try? JSONDecoder().decode(RetentionChoice.self, from: Data(json.utf8)) else { return }
        choice = saved
    }

    func update(_ choice: RetentionChoice, in history: PolishHistory?) async {
        guard choice != self.choice else { return }
        self.choice = choice
        await persist()
        await purge(history)
    }

    /// The store is the truth on disk; the window's list is the truth on screen. Both are
    /// brought to the new policy here, because a cleared draft that stays visible in the
    /// table until the next launch is exactly the promise this setting makes.
    func purge(_ history: PolishHistory?) async {
        guard let records else { return }
        let now = Date()
        do {
            lastPurge = try await records.purge(choice.policy, now: now)
            failure = nil
        } catch {
            failure = (error as? LocalizedError)?.errorDescription ?? L10n.tr("按新的保留策略清理时出错。")
        }
        if let history { reconcile(history, now: now) }
    }

    private func persist() async {
        guard let preferences, let data = try? JSONEncoder().encode(choice) else { return }
        do {
            try await preferences.set(String(decoding: data, as: UTF8.self), forKey: Self.preferenceKey)
        } catch {
            failure = L10n.tr("保留策略没能写进设置，下次启动会回到上一次保存的那份。")
        }
    }

    /// Mirrors `SQLiteRecordStore.purge` on the loaded rows: delete by age, then by count,
    /// then blank what is left and old enough — in that order, so a row is never blanked and
    /// then removed.
    private func reconcile(_ history: PolishHistory, now: Date) {
        let policy = choice.policy
        let ordered = history.records.sorted { $0.createdAt > $1.createdAt }
        var doomed: Set<UUID> = []
        if let maxAge = policy.maxAge {
            let cutoff = now.addingTimeInterval(-maxAge)
            doomed.formUnion(ordered.lazy.filter { $0.createdAt < cutoff }.map(\.id))
        }
        if let maxCount = policy.maxCount {
            let survivors = ordered.filter { !doomed.contains($0.id) }
            doomed.formUnion(survivors.dropFirst(max(maxCount, 0)).map(\.id))
        }
        for id in doomed { history.remove(id) }
        guard let textMaxAge = policy.textMaxAge else { return }
        let cutoff = now.addingTimeInterval(-textMaxAge)
        for record in ordered where !doomed.contains(record.id) && record.createdAt < cutoff {
            guard record.originalText != nil || record.resultText != nil else { continue }
            var blanked = record
            blanked.originalText = nil
            blanked.resultText = nil
            blanked.updatedAt = now
            history.save(blanked)
        }
    }
}

/// Settings ▸ 历史. The storage sentence that used to be pinned to the bottom of the activity
/// window lives here, next to the settings that decide what it says.
struct HistorySettingsPane: View {
    let model: AppModel
    var retention: RetentionSettings = .shared

    @State private var clearing = false

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Metric.gap12, verticalSpacing: Metric.gap12) {
            GridRow {
                SettingsLabel(L10n.tr("保留记录"), width: SettingsMetric.wideLabelWidth)
                HStack(spacing: Metric.gap8) {
                    Picker(L10n.tr("保留记录"), selection: age) {
                        ForEach(RetentionChoice.ageOptions, id: \.self) { option in
                            Text(RetentionChoice.ageLabel(option)).tag(option)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    Text(L10n.tr("或")).foregroundStyle(.secondary)
                    Picker(L10n.tr("最多条数"), selection: count) {
                        ForEach(RetentionChoice.countOptions, id: \.self) { option in
                            Text(RetentionChoice.countLabel(option)).tag(option)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
            GridRow {
                SettingsLabel(L10n.tr("清除正文"), width: SettingsMetric.wideLabelWidth)
                HStack(spacing: Metric.gap8) {
                    Picker(L10n.tr("清除正文"), selection: textClear) {
                        ForEach(RetentionChoice.textOptions, id: \.self) { option in
                            Text(RetentionChoice.textLabel(option)).tag(option)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    Text(L10n.tr("之后只留下这条记录本身")).font(.caption).foregroundStyle(.secondary)
                }
            }
            if let report = retention.lastPurge, report.deletedRows + report.blankedTexts > 0 {
                GridRow {
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    Text(L10n.format("刚刚清理 %@ 条，清空正文 %@ 条", String(describing: report.deletedRows), String(describing: report.blankedTexts)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let failure = retention.failure {
                GridRow {
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    Label {
                        Text(failure)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").filledGlyph(.orange)
                    }
                    .font(.caption)
                }
            }
            GridRow {
                SettingsLabel(L10n.tr("位置"), width: SettingsMetric.wideLabelWidth)
                HStack(spacing: Metric.gap8) {
                    Text(pathText)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .textSelection(.enabled)
                    Button(L10n.tr("显示")) { reveal() }
                        .disabled(databaseURL == nil)
                }
            }
            GridRow {
                SettingsLabel(L10n.tr("权限"), width: SettingsMetric.wideLabelWidth)
                Text(L10n.tr("目录 0700 · 文件 0600 · 撤回数据只在内存，退出即失"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            GridRow {
                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                HStack(spacing: Metric.gap8) {
                    Button(L10n.tr("清空历史…"), role: .destructive) { clearing = true }
                        .disabled(model.activity.totalCount == 0)
                    Text(L10n.format("当前 %@ 条 · ⇧⌘⌫", String(describing: model.activity.totalCount)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, Metric.gap4)
            }
        }
        .padding(.horizontal, Metric.gap20)
        .padding(.vertical, Metric.gap20)
        // The 620 is the window's, stated once on the `TabView`; a pane fills what the tab
        // bar leaves it rather than measuring the window a second time.
        .frame(maxWidth: .infinity, alignment: .leading)
        .confirmationDialog(L10n.format("清空全部 %@ 条记录？", String(describing: model.activity.totalCount)), isPresented: $clearing) {
            Button(L10n.tr("清空历史"), role: .destructive) { model.activity.clearAll() }
            Button(L10n.tr("取消"), role: .cancel) {}
        } message: {
            Text(L10n.tr("记录和正文都会从数据库删除，无法恢复。"))
        }
    }

    // MARK: - Bindings

    /// Each picker writes the whole choice, because the store persists and purges as one
    /// action and there is no such thing as half a retention policy.
    private var age: Binding<Int?> {
        binding(\.maxAgeDays)
    }

    private var count: Binding<Int?> {
        binding(\.maxCount)
    }

    private var textClear: Binding<Int?> {
        binding(\.textClearDays)
    }

    private func binding(_ field: WritableKeyPath<RetentionChoice, Int?>) -> Binding<Int?> {
        Binding {
            retention.choice[keyPath: field]
        } set: { value in
            var updated = retention.choice
            updated[keyPath: field] = value
            Task { await retention.update(updated, in: model.history) }
        }
    }

    // MARK: - Location

    private var databaseURL: URL? {
        guard let location = try? Database.applicationSupportLocation(),
              case .file(let url) = location else { return nil }
        return url
    }

    private var pathText: String {
        guard let databaseURL else { return model.storageNote ?? L10n.tr("历史只保存在内存中。") }
        return databaseURL.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    private func reveal() {
        guard let databaseURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([databaseURL])
    }
}
