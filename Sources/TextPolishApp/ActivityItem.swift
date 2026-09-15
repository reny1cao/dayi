import AppKit
import Foundation
import PolishCore
import PolishStore
import SwiftUI

/// The eight states a row can be in. Seven come from the model (`ComputeState` ×
/// `ApplicationState`, collapsed the same way `Outcome` collapses them) plus `running`,
/// which is a compute state rather than an application one. There is no ninth: every
/// surface that needs a glyph, a colour, a sentence or a set of buttons derives it here.
enum ActivityState: String, CaseIterable, Hashable, Sendable {
    case running, pending, blocked, applying, applied, uncertain, undone, failed

    /// The status column has no visible text, so this string is what VoiceOver reads and
    /// what the state sort is described by.
    var name: String {
        switch self {
        case .running: L10n.tr("润色中")
        case .pending: L10n.tr("结果就绪")
        case .blocked: L10n.tr("待应用")
        case .applying: L10n.tr("正在应用")
        case .applied: L10n.tr("已应用")
        case .uncertain: L10n.tr("写入不确定")
        case .undone: L10n.tr("已撤回")
        case .failed: L10n.tr("失败")
        }
    }

    /// `running` and `applying` are drawn as a `ProgressView`; the symbol is the fallback for
    /// the places that cannot spin one (a menu row, a printed list).
    var symbol: String {
        switch self {
        case .running, .applying: "circle.dashed"
        case .pending: "circle.dotted"
        case .blocked: "arrow.right.circle.fill"
        case .applied: "checkmark.circle.fill"
        case .uncertain: "exclamationmark.triangle.fill"
        case .undone: "arrow.uturn.backward.circle"
        case .failed: "xmark.circle.fill"
        }
    }

    /// Colour lives in the glyph and nowhere else. `nil` means the glyph follows the label
    /// colour of whatever draws it, which is also what a selected row needs.
    var tint: Color? {
        switch self {
        case .running, .applying: nil
        case .pending: Color(nsColor: .secondaryLabelColor)
        case .blocked: .orange
        case .applied: .green
        case .uncertain, .failed: .red
        case .undone: Color(nsColor: .tertiaryLabelColor)
        }
    }

    /// Whether the glyph carries its mark on a second layer. Painted with one palette colour
    /// a `.fill` symbol collapses into a flat disc, and the state stops being a shape — which
    /// is the whole reason DESIGN.md §12 forbids carrying state in colour alone.
    var hasMarkLayer: Bool { symbol.hasSuffix(".fill") }

    /// The half sentence the inspector's title carries after the state name — "待应用 ·
    /// 结果已生成，尚未写回". Its job is one glance; `ActivityItem.sentence` below it is the
    /// one that explains why, so this never repeats that.
    var qualifier: String {
        switch self {
        case .running: L10n.tr("已发出请求")
        case .pending: L10n.tr("结果就绪，正在写回")
        case .blocked: L10n.tr("结果已生成，尚未写回")
        case .applying: L10n.tr("正在写回原位置")
        case .applied: L10n.tr("后台写回")
        case .uncertain: L10n.tr("已停止自动操作")
        case .undone: L10n.tr("原文已恢复")
        case .failed: L10n.tr("没有产生结果")
        }
    }

    /// Sorting the status column is by lifecycle, in the order the design's state table
    /// lists them, not by the alphabet of a string no column shows.
    var sortRank: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}

/// One action a row offers. Which ones are legal is a property of the state, and of whether
/// the in-memory context survived; see `ActivityItem.actions`.
enum ActivityAction: String, Identifiable, Hashable, CaseIterable, Sendable {
    case jumpBack, copyResult, returnToContext, undo, retry, checkModel

    var id: String { rawValue }

    /// Every label names the application, because "跳回" without a name is a guess.
    func title(for item: ActivityItem) -> String {
        switch self {
        case .jumpBack: L10n.format("跳回 %@", String(describing: item.targetLabel))
        case .copyResult: L10n.tr("复制结果")
        case .returnToContext: L10n.tr("返回原位置")
        case .undo: L10n.tr("撤回替换")
        case .retry: L10n.tr("回到原位重试")
        case .checkModel: L10n.tr("检查模型设置")
        }
    }

    var symbol: String {
        switch self {
        case .jumpBack: "arrow.right.circle"
        case .copyResult: "doc.on.doc"
        case .returnToContext: "arrow.uturn.left"
        case .undo: "arrow.uturn.backward"
        case .retry: "arrow.clockwise"
        case .checkModel: "gearshape"
        }
    }

    /// The keystroke that does the same thing without the pointer, shown next to the footer.
    /// 撤回 is a global hot key the person can rebind, so it is read rather than spelled.
    @MainActor var shortcutHint: String? {
        switch self {
        case .jumpBack: "↩"
        case .copyResult: "⌘C"
        case .undo: HotKeyBindings.shared.undo.display
        case .returnToContext, .retry, .checkModel: nil
        }
    }

    /// At most one filled accent button per surface; in the inspector this is the one.
    var isProminent: Bool { self == .jumpBack }
}

/// A live job and a stored record are the same object at different ages. The table is given
/// this projection so it never has to ask which of the two it is showing, and so the state
/// table is applied once instead of once per view.
struct ActivityItem: Identifiable, Equatable, Hashable {
    let id: UUID
    let targetLabel: String
    let website: WebsiteSource?
    var sourceLabel: String { website?.host ?? targetLabel }
    let originalText: String?
    let resultText: String?
    let model: String?
    let state: ActivityState
    let message: String?
    let createdAt: Date
    let updatedAt: Date
    /// Wall time from the press to the last state change; the live seconds while running.
    let duration: Double?
    /// The job is still in memory, so the target handle, the undo edit and the waiting result
    /// exist. Contexts are never persisted: quitting the app ends every one of them.
    let isLive: Bool
    /// No retained text: capture may have failed, or retention may have cleared it.
    let textCleared: Bool

    /// The six strings a table row draws, rendered when the item is built rather than when a
    /// cell is asked to draw. A cell body runs on the scroll path, and `Calendar.isDateInToday`
    /// and `DateFormatter.string(from:)` are not cheap — doing them per cell per frame is how a
    /// forty-row list drops frames. Items are rebuilt only when the data behind them changes,
    /// so this work happens once per change instead of once per frame.
    let previewText: String
    let modelText: String
    let durationText: String
    let timeText: String
    /// The status cell is first in the row, so it carries the whole row for VoiceOver.
    let rowSummary: String

    /// Projects a live job. `record` is the row this job last wrote, which is the only place
    /// a finish time exists — `PolishJob` carries the start and nothing else.
    init(job: PolishJob, storedAs record: PolishRecord? = nil, elapsed: Double? = nil) {
        id = job.id
        targetLabel = job.targetLabel
        website = job.website
        originalText = job.originalText
        resultText = job.result
        model = job.model.isEmpty ? nil : job.model
        state = ActivityState(compute: job.computeState, application: job.applicationState)
        message = job.failure?.message ?? job.message
        createdAt = job.createdAt
        updatedAt = record?.updatedAt ?? job.createdAt
        duration = if job.computeState == .running {
            elapsed
        } else if let record {
            record.updatedAt.timeIntervalSince(record.createdAt)
        } else {
            nil
        }
        isLive = true
        textCleared = false
        (previewText, modelText, durationText, timeText, rowSummary) =
            Self.render(originalText: originalText, model: model, duration: duration,
                        createdAt: createdAt, targetLabel: website.map { "\($0.host) · \(job.targetLabel)" } ?? targetLabel, state: state)
    }

    /// Projects a stored record. Nothing here can be applied, undone or returned to: the
    /// accessibility element it named belongs to a process that may not exist any more.
    init(record: PolishRecord, elapsed: Double? = nil) {
        id = record.id
        targetLabel = record.targetLabel
        website = record.website
        originalText = record.originalText
        resultText = record.resultText
        model = record.model
        state = ActivityState(outcome: record.outcome)
        message = record.failure?.message ?? record.message
        createdAt = record.createdAt
        updatedAt = record.updatedAt
        duration = record.outcome == .running ? elapsed : record.updatedAt.timeIntervalSince(record.createdAt)
        isLive = false
        textCleared = record.originalText == nil
        (previewText, modelText, durationText, timeText, rowSummary) =
            Self.render(originalText: originalText, model: model, duration: duration,
                        createdAt: createdAt, targetLabel: website.map { "\($0.host) · \(record.targetLabel)" } ?? targetLabel, state: state)
    }

    /// One pass over everything a row draws. `Calendar.current` is fetched once here rather
    /// than once per string.
    private static func render(
        originalText: String?, model: String?, duration: Double?,
        createdAt: Date, targetLabel: String, state: ActivityState
    ) -> (String, String, String, String, String) {
        let preview = originalText ?? L10n.tr("无可用正文")
        let modelName = model ?? L10n.tr("模型未记录")
        let elapsed = duration.map { String(format: "%.1f", $0) } ?? "—"
        let calendar = Calendar.current
        let time: String
        if calendar.isDateInToday(createdAt) {
            time = clock.string(from: createdAt)
        } else if calendar.isDateInYesterday(createdAt) {
            time = L10n.tr("昨天")
        } else {
            time = day.string(from: createdAt)
        }
        let summary = "\(targetLabel)，\(state.name)，\(preview.prefix(30))，\(modelName)，\(time)"
        return (preview, modelName, elapsed, time, summary)
    }
}

extension ActivityState {
    init(compute: ComputeState, application: ApplicationState) {
        switch compute {
        case .running: self = .running
        case .failed: self = .failed
        case .succeeded:
            switch application {
            case .pending: self = .pending
            case .blocked: self = .blocked
            case .applying: self = .applying
            case .applied: self = .applied
            case .uncertain: self = .uncertain
            case .undone: self = .undone
            }
        }
    }

    /// `Outcome.waiting` collapsed `pending` and `blocked` on the way to disk. A row read
    /// back is by definition one nobody applied, which is what `blocked` says; `pending` is a
    /// state that only exists for the moment a write is being attempted.
    init(outcome: Outcome) {
        switch outcome {
        case .running: self = .running
        case .failed: self = .failed
        case .waiting: self = .blocked
        case .applying: self = .applying
        case .applied: self = .applied
        case .uncertain: self = .uncertain
        case .undone: self = .undone
        }
    }
}

extension ActivityItem {
    var symbol: String { state.symbol }
    var tint: Color? { state.tint }

    /// The plain-language line for this row, naming the application every time: "已替换" is
    /// useless, "已替换 · Codex" is not. The blocked line ends on the key that rescues the
    /// result, read off the live registration — pointing at a combination the person rebound
    /// would be pointing at a key that is no longer registered.
    @MainActor var sentence: String {
        switch state {
        case .running: L10n.format("已发出请求，正在润色 %@ 的选区。", String(describing: targetLabel))
        case .pending: L10n.format("结果就绪，正在写回 %@。", String(describing: targetLabel))
        case .blocked: L10n.format("网页输入区不支持后台写回 —— 回到 %@ 按 %@。", String(describing: targetLabel), String(describing: HotKeyBindings.shared.polish.display))
        case .applying: L10n.format("正在写回 %@。", String(describing: targetLabel))
        case .applied: L10n.format("已写回 %@ 原位 · 回读一致。", String(describing: targetLabel))
        case .uncertain: L10n.format("无法确认写回 %@ 的结果；已停止自动操作。", String(describing: targetLabel))
        case .undone: L10n.format("已恢复 %@ 的原文。", String(describing: targetLabel))
        case .failed: message ?? L10n.format("%@ 的润色请求未完成。", String(describing: targetLabel))
        }
    }

    /// The actions this state allows, minus the ones whose target died with the context.
    var actions: [ActivityAction] {
        let copy: [ActivityAction] = hasResult ? [.copyResult] : []
        switch state {
        case .running: return isLive ? [.returnToContext] : []
        case .pending, .applying: return []
        case .blocked: return (isLive ? [.jumpBack] : []) + copy
        case .applied: return (isLive ? [.undo] : []) + copy + (isLive ? [.returnToContext] : [])
        case .uncertain: return copy + (isLive ? [.returnToContext] : [])
        case .undone: return copy
        case .failed: return (isLive ? [.retry] : []) + [.checkModel]
        }
    }

    var hasResult: Bool { !(resultText ?? "").isEmpty }

    /// Second precision, for the inspector only: it is the one place two records are compared.
    var timestampText: String { Self.precise.string(from: createdAt) }

    /// Website and application labels remain searchable after draft retention expires.
    func matches(_ query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        return [originalText, resultText, website?.host, targetLabel].contains {
            $0?.localizedCaseInsensitiveContains(trimmed) == true
        }
    }

    fileprivate static let clock = formatter("HH:mm")
    fileprivate static let day = formatter("Md")
    private static let precise = formatter("HH:mm:ss")

    private static func formatter(_ template: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = L10n.locale
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter
    }
}
