import AppKit
import Foundation
import Observation
import PolishCore
import SwiftUI

/// The right-hand inspector. Every long string in this application lives here, which is what
/// lets the table stay one line per record: depth is one column away rather than one screen.
/// The section order never changes — 状态 · 目标 · 模型 · 原文 · 润色后 · footer — because the
/// eye learns a position faster than it reads a label.
struct RecordInspector: View {
    let store: ActivityStore
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        content
            // The column is 300pt wide and separated from the table by one hairline; both come
            // from the split view that hosts this, so the width is not clamped here — clamping
            // it would leave window background behind a widened column. Content is opaque:
            // nothing in this window is allowed to be translucent except the HUD.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder private var content: some View {
        if let item = store.selected {
            detail(item)
        } else if store.selection.count > 1 {
            batch(store.selection)
        } else {
            placeholder
        }
    }

    // MARK: - One record

    func detail(_ item: ActivityItem) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Metric.sectionGap) {
                    status(item)
                    Divider()
                    target(item)
                    Divider()
                    model(item)
                    Divider()
                    RecordText(item: item)
                }
                .padding(Metric.inspectorPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if hasFooter(item) { footer(item) }
        }
    }

    // MARK: - 状态

    private func status(_ item: ActivityItem) -> some View {
        VStack(alignment: .leading, spacing: Metric.itemGap) {
            InspectorSectionHeader(L10n.tr("状态"))
            HStack(alignment: .top, spacing: Metric.itemGap) {
                StateGlyph(state: item.state, scale: .large)
                VStack(alignment: .leading, spacing: Metric.labelGap) {
                    // 状态名 · 一句限定语. The qualifier is the glance; the sentence under it is
                    // the explanation, and they never say the same thing twice.
                    Text("\(item.state.name) · \(item.state.qualifier)")
                        .font(.body.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true)
                    InlineSentence(item.sentence)
                    Text(meta(item))
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// Measured latency spans 2.3–19.3s, so the number is the answer rather than "a while".
    /// A waiting result is named as perishable here because nothing else on screen says that
    /// quitting the application ends it.
    private func meta(_ item: ActivityItem) -> String {
        var parts: [String] = []
        if item.duration != nil { parts.append(L10n.format("%@ 秒", String(describing: item.durationText))) }
        parts.append(item.timestampText)
        if item.state == .blocked { parts.append(item.isLive ? L10n.tr("退出后丢失") : L10n.tr("上下文已失效")) }
        return parts.joined(separator: " · ")
    }

    // MARK: - 目标

    /// The one place the product's hardest constraint is visible: a web or Electron input area
    /// has no background write path, which is the whole reason a result ever waits. Rows the
    /// record cannot prove are omitted rather than filled with a placeholder — an unknown AX
    /// role printed as "未知" would read as a measurement.
    private func target(_ item: ActivityItem) -> some View {
        let facts = TargetFactsLog.shared.facts[item.id]
        let background = facts?.supportsBackgroundWrite ?? (item.state == .blocked ? false : nil)
        return VStack(alignment: .leading, spacing: Metric.itemGap) {
            InspectorSectionHeader(L10n.tr("目标"))
            Grid(alignment: .leadingFirstTextBaseline,
                 horizontalSpacing: Metric.gap12, verticalSpacing: Metric.labelGap) {
                GridRow {
                    fieldLabel(L10n.tr("应用"))
                    HStack(spacing: Metric.gap4) {
                        AppBadge(label: item.targetLabel, size: Metric.inspectorBadgeSize)
                        Text(item.targetLabel)
                    }
                }
                if let facts {
                    GridRow {
                        fieldLabel(L10n.tr("输入区"))
                        Text(facts.inputText).font(.caption.monospaced())
                    }
                }
                if let website = item.website {
                    GridRow {
                        fieldLabel(L10n.tr("网站"))
                        Text(website.host).textSelection(.enabled)
                    }
                }
                if let background {
                    GridRow {
                        fieldLabel(L10n.tr("后台写回"))
                        // Colour lives in the glyph; the word stays `labelColor`. systemOrange
                        // on 11pt text over `windowBackgroundColor` is the ~2:1 the design
                        // system names by number and refuses — a filled symbol is a shape
                        // first, so it survives Increase Contrast and colour blindness too.
                        Label {
                            Text(background ? L10n.tr("支持") : L10n.tr("不支持"))
                        } icon: {
                            Image(systemName: background ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .filledGlyph(background ? AnyShapeStyle(.green) : AnyShapeStyle(.orange))
                        }
                        .labelStyle(.titleAndIcon)
                    }
                }
                if let facts {
                    GridRow {
                        fieldLabel(L10n.tr("选区"))
                        Text(facts.rangeText).font(.caption.monospaced())
                    }
                }
            }
            .font(.caption)
        }
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .gridColumnAlignment(.leading)
    }

    // MARK: - 模型

    private func model(_ item: ActivityItem) -> some View {
        let preset = InspectorProvider.preset(for: item.model)
        return VStack(alignment: .leading, spacing: Metric.itemGap) {
            InspectorSectionHeader(L10n.tr("模型"))
            HStack(alignment: .top, spacing: Metric.gap8) {
                logo(for: preset)
                modelLine(item, preset)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder private func logo(for preset: ProviderPreset?) -> some View {
        if let preset {
            // One point under the settings form's logo: here it sits beside 11pt text.
            ProviderIcon.image(for: preset, in: InspectorProvider.catalog, size: 15)
        } else {
            Image(systemName: "cloud")
                .imageScale(.medium)
                .foregroundStyle(.secondary)
        }
    }

    /// One wrapping paragraph rather than an `HStack`, so a long model id and its thinking
    /// setting break across lines instead of being squeezed out of a 300pt column.
    private func modelLine(_ item: ActivityItem, _ preset: ProviderPreset?) -> Text {
        let id = Text(item.modelText).font(.caption.monospaced())
        // A row that never recorded which model answered says so in the tertiary weight the
        // table uses for the same absence.
        let name = item.model == nil ? id.foregroundStyle(.tertiary) : id.foregroundStyle(.primary)
        guard let note = InspectorProvider.thinkingNote(preset) else { return name }
        return name + Text(" · \(note)").font(.caption).foregroundStyle(.secondary)
    }

    // MARK: - footer

    /// Only the actions this state allows, and nothing else. A record read back from disk has
    /// no context left to jump to or undo, so what remains of it is a record: copy and delete.
    private func hasFooter(_ item: ActivityItem) -> Bool { !item.actions.isEmpty || !item.isLive }

    private func footer(_ item: ActivityItem) -> some View {
        VStack(alignment: .leading, spacing: Metric.itemGap) {
            if item.state == .applied {
                Text(L10n.tr("撤回要求受保护前缀未变；已实现范围内的后缀编辑允许，冲突时保留现状。"))
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
            HStack(spacing: Metric.gap8) {
                ForEach(item.actions) { action in
                    actionButton(action, item)
                }
                if !item.isLive {
                    Button(L10n.tr("删除这条"), role: .destructive) { store.delete([item.id]) }
                        .buttonStyle(.bordered)
                        .lineLimit(1)
                }
                Spacer(minLength: Metric.gap8)
                if let hint = item.actions.compactMap({ $0.shortcutHint }).first {
                    Text(hint)
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, Metric.inspectorPadding)
        .padding(.vertical, Metric.footerPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Divider() }
    }

    /// `perform` reports false for exactly one action — the one only a view can carry out.
    @ViewBuilder private func actionButton(_ action: ActivityAction, _ item: ActivityItem) -> some View {
        let button = Button(action.title(for: item)) {
            if !store.perform(action, on: item) {
                // 检查模型设置 means one specific tab, and `openSettings()` cannot say which.
                SettingsRoute.shared.show(.model)
                openSettings()
            }
        }
        .lineLimit(1)
        if action.isProminent {
            // The single filled accent button in this window, and the ↩ the footer advertises.
            button.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
        } else {
            button.buttonStyle(.bordered)
        }
    }

    // MARK: - No single record

    private func batch(_ selection: Set<UUID>) -> some View {
        VStack(spacing: Metric.gap12) {
            Text(L10n.format("已选 %@ 条记录", String(describing: selection.count)))
                .font(.body.weight(.medium))
            Text(L10n.tr("检查器一次只讲一条记录。"))
                .font(.caption)
                .foregroundStyle(.secondary)
            Button(L10n.format("删除这 %@ 条", String(describing: selection.count)), role: .destructive) { store.delete(selection) }
                .buttonStyle(.bordered)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Metric.gap20)
    }

    private var placeholder: some View {
        Text(L10n.tr("选中一条记录，这里显示它的目标、模型和全文。"))
            .font(.body)
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(Metric.gap20)
    }
}

// MARK: - 原文 / 润色后

/// The two long sections, and the only diff in the application. They share one computation:
/// the same comparison produces the removals marked in 原文 and the additions marked in 润色后.
private struct RecordText: View {
    let item: ActivityItem
    @State private var marks = DiffMarks.none

    var body: some View {
        VStack(alignment: .leading, spacing: Metric.sectionGap) {
            section(L10n.tr("原文"), count: originalCount) { original }
            // A result that does not exist yet is not an empty section; it is no section.
            if item.state != .running, item.hasResult, let result = item.resultText {
                section(L10n.tr("润色后"), count: resultCount(result)) {
                    ExpandableText(text: marks.result(result))
                }
            }
        }
        .task(id: item) {
            let before = item.originalText, after = item.resultText
            // Myers stays near-linear on similar drafts but is quadratic in the worst case,
            // and this runs while someone is reading; it does not belong on the main actor.
            let computed = await Task.detached { DiffMarks(original: before, result: after) }.value
            guard !Task.isCancelled else { return }
            marks = computed
        }
    }

    private func section(_ title: String, count: String?, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Metric.itemGap) {
            HStack(alignment: .firstTextBaseline, spacing: Metric.gap8) {
                InspectorSectionHeader(title)
                if let count {
                    Text(count)
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                }
            }
            content()
        }
    }

    @ViewBuilder private var original: some View {
        if let text = item.originalText {
            ExpandableText(text: marks.original(text))
        } else {
            // Capture failures have no text; retention can also clear an older record.
            Text(item.previewText)
                .font(.body)
                .italic()
                .foregroundStyle(.tertiary)
        }
    }

    private var originalCount: String? {
        item.originalText.map { L10n.format("%@ 字", String(describing: $0.count)) }
    }

    private func resultCount(_ result: String) -> String {
        L10n.format("%@ 字 · %@", String(describing: result.count), String(describing: writeNote))
    }

    private var writeNote: String {
        switch item.state {
        case .applied: L10n.tr("已写入")
        case .undone: L10n.tr("已撤回")
        case .uncertain: L10n.tr("写入不确定")
        default: L10n.tr("未写入")
        }
    }
}

/// `Text` clamps silently, so the same string is laid out unclamped behind the visible one and
/// the two heights compared: without that there is no way to tell a reader that the rest of
/// their draft is still there.
private struct ExpandableText: View {
    let text: AttributedString

    @State private var expanded = false
    @State private var clipped = false
    @State private var clampedHeight: CGFloat = 0
    @State private var fullHeight: CGFloat = 0

    /// The canvas clamps at seven lines; past that the inspector stops being a summary of a
    /// record and becomes a document window.
    private static let visibleLines = 7

    var body: some View {
        VStack(alignment: .leading, spacing: Metric.labelGap) {
            styled
                .lineLimit(expanded ? nil : Self.visibleLines)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background { height { clampedHeight = $0 } }
                .background(alignment: .topLeading) {
                    styled
                        .fixedSize(horizontal: false, vertical: true)
                        .hidden()
                        .accessibilityHidden(true)
                        .background { height { fullHeight = $0 } }
                }
            if clipped {
                Button {
                    expanded.toggle()
                } label: {
                    Label(expanded ? L10n.tr("收起") : L10n.tr("展开"), systemImage: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .onChange(of: text) { expanded = false }
        .onChange(of: fullHeight) { refresh() }
        .onChange(of: clampedHeight) { refresh() }
    }

    /// The diff lives in the fills; the characters themselves are always `labelColor`.
    private var styled: some View {
        Text(text)
            .font(.body)
            .lineSpacing(Metric.gap4)
            .foregroundStyle(.primary)
    }

    private func refresh() {
        // Expanding makes the two heights agree, which would retract the control that undoes it.
        guard !expanded else { return }
        clipped = fullHeight - clampedHeight > 1
    }

    private func height(_ report: @escaping (CGFloat) -> Void) -> some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear { report(proxy.size.height) }
                .onChange(of: proxy.size.height) { report(proxy.size.height) }
        }
    }
}

// MARK: - Diff

/// What changed between the selection and the answer, per character. Chinese compares and
/// breaks per character, and a word-level diff of it would mark whole clauses as replaced.
private struct DiffMarks: Sendable {
    /// Offsets into the original that the answer dropped.
    let removals: Set<Int>
    /// Offsets into the answer the original did not have.
    let additions: Set<Int>

    static let none = DiffMarks(original: nil, result: nil)

    /// Past this length a draft is being read rather than compared, and the quadratic worst
    /// case of the difference stops being free.
    private static let limit = 2000

    init(original: String?, result: String?) {
        var removals: Set<Int> = []
        var additions: Set<Int> = []
        if let original, let result, !original.isEmpty, !result.isEmpty,
           original.count <= Self.limit, result.count <= Self.limit {
            for change in Array(result).difference(from: Array(original)) {
                switch change {
                case .remove(let offset, _, _): removals.insert(offset)
                case .insert(let offset, _, _): additions.insert(offset)
                }
            }
        }
        self.removals = removals
        self.additions = additions
    }

    func original(_ text: String) -> AttributedString {
        Self.marked(text, at: removals, fill: .red, opacity: Metric.removalFill, struck: true)
    }

    func result(_ text: String) -> AttributedString {
        Self.marked(text, at: additions, fill: .green, opacity: Metric.additionFill, struck: false)
    }

    /// Adjacent marked characters are merged into one run, so a rewritten clause reads as one
    /// highlighted phrase rather than a row of separate boxes.
    private static func marked(_ text: String, at offsets: Set<Int>, fill: Color,
                               opacity: Double, struck: Bool) -> AttributedString {
        guard !offsets.isEmpty else { return AttributedString(text) }
        var output = AttributedString()
        var run = ""
        var runMarked = false
        func flush() {
            guard !run.isEmpty else { return }
            var piece = AttributedString(run)
            if runMarked {
                // Written through the SwiftUI scope: AppKit exports attributes of the same
                // names carrying `NSColor` and `NSUnderlineStyle`.
                var attributes = AttributeContainer()
                attributes.swiftUI.backgroundColor = fill.opacity(opacity)
                if struck { attributes.swiftUI.strikethroughStyle = .single }
                piece.mergeAttributes(attributes)
            }
            output.append(piece)
            run = ""
        }
        for (offset, character) in text.enumerated() {
            let marked = offsets.contains(offset)
            if marked != runMarked {
                flush()
                runMarked = marked
            }
            run.append(character)
        }
        flush()
        return output
    }
}

// MARK: - Target facts

/// What the accessibility target was. `PolishJob` carries the application's name and nothing
/// else about the element: the AX role, the write capability and the selected range live on
/// `AXTextTarget` and its `TextSnapshot`, both of which `PolishJobs` keeps privately and this
/// phase may not change. So the capture path records them here by job id, and the inspector
/// draws the rows it has. Nothing is persisted: an element handle outlives neither the target
/// process nor this one, so a fact about it would be a claim about something already gone.
struct TargetFacts: Hashable, Sendable {
    let role: String
    let isWeb: Bool
    let supportsBackgroundWrite: Bool
    let location: Int
    let length: Int

    var inputText: String { "\(role) · \(isWeb ? "web" : L10n.tr("原生"))" }
    /// Ranges are measured in UTF-16 units, and saying so is the difference between a number
    /// a person can check against their editor and a number they cannot.
    var rangeText: String { "UTF-16 {\(location), \(length)}" }
}

@MainActor @Observable
final class TargetFactsLog {
    static let shared = TargetFactsLog()
    private(set) var facts: [UUID: TargetFacts] = [:]

    private init() {}

    func record(_ facts: TargetFacts, for id: UUID) { self.facts[id] = facts }
    func forget(_ id: UUID) { facts[id] = nil }
}

// MARK: - Provider

/// The bundled catalogue, read once. A record keeps the model id the provider answered with,
/// so the logo is looked up from that id rather than from whatever Settings holds now — the
/// profile may have moved on several times since this row was written.
@MainActor
private enum InspectorProvider {
    static let catalog = try? ProviderCatalog.bundled()

    /// An id two providers both serve names neither of them. A generic glyph is honest; the
    /// wrong brand mark is not.
    static func preset(for model: String?) -> ProviderPreset? {
        guard let model, let catalog else { return nil }
        let named = catalog.providers.filter { $0.model == model }
        if named.count == 1 { return named[0] }
        let listed = catalog.providers.filter { $0.models.contains(model) }
        return listed.count == 1 ? listed[0] : nil
    }

    /// How the request was shaped. The record does not carry it, so this is the catalogue
    /// entry the profile for that model is built from.
    static func thinkingNote(_ preset: ProviderPreset?) -> String? {
        guard let preset else { return nil }
        if preset.thinking == .disabled { return "thinking off" }
        let effort = preset.reasoningEffort.trimmingCharacters(in: .whitespacesAndNewlines)
        return effort.isEmpty ? nil : "reasoning \(effort)"
    }
}

// MARK: - A sentence with a key in it

/// The blocked line has to end in the literal keystroke to press, drawn as a key rather than
/// quoted — and `Text` cannot host a view. Sentences without a key stay one `Text`, so only
/// the one line that needs hand-laid runs pays for them.
private struct InlineSentence: View {
    let sentence: String

    init(_ sentence: String) { self.sentence = sentence }

    /// Both global combinations are rebindable, so what counts as a key cap is whatever is
    /// registered now — splitting on a hard-coded "⌃⌥P" would leave a rebound sentence with
    /// its key drawn as plain text.
    private var keys: [String] {
        [HotKeyBindings.shared.polish.display, HotKeyBindings.shared.undo.display]
    }

    var body: some View {
        Group {
            if keys.contains(where: sentence.contains) {
                InlineFlow(lineSpacing: Metric.gap4) {
                    ForEach(Array(Self.runs(of: sentence, keys: keys).enumerated()), id: \.offset) { _, run in
                        switch run {
                        case .text(let value): Text(value).font(.caption)
                        case .key(let value): KeyCap(text: value)
                        }
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(sentence)
            } else {
                Text(sentence)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .foregroundStyle(.secondary)
    }

    private enum Run {
        case text(String)
        case key(String)
    }

    /// Runs a line may break between: each CJK character on its own, Latin words and numbers
    /// whole, and the shortcuts lifted out to be drawn as keys.
    private static func runs(of sentence: String, keys: [String]) -> [Run] {
        var runs: [Run] = []
        var word = ""
        var index = sentence.startIndex

        func flush() {
            guard !word.isEmpty else { return }
            runs.append(.text(word))
            word = ""
        }

        while index < sentence.endIndex {
            if let key = keys.first(where: { sentence[index...].hasPrefix($0) }) {
                flush()
                runs.append(.key(key))
                index = sentence.index(index, offsetBy: key.count)
                continue
            }
            let character = sentence[index]
            if (character.isLetter && character.isASCII) || character.isNumber || character == "." || character == "-" {
                word.append(character)
            } else {
                flush()
                runs.append(.text(String(character)))
            }
            index = sentence.index(after: index)
        }
        flush()
        return runs
    }
}

/// A flow layout, existing only so a key cap can sit inside a sentence. Rows are centred on
/// each other because a key is taller than the text it interrupts.
private struct InlineFlow: Layout {
    var spacing: CGFloat = 0
    var lineSpacing: CGFloat = 0

    private struct Item {
        let index: Int
        let size: CGSize
    }

    private struct Line {
        var items: [Item] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let available = proposal.width ?? .greatestFiniteMagnitude
        let rows = lines(of: subviews, within: available)
        let height = rows.reduce(0) { $0 + $1.height } + lineSpacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width ?? (rows.map(\.width).max() ?? 0), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for line in lines(of: subviews, within: bounds.width) {
            var x = bounds.minX
            for item in line.items {
                subviews[item.index].place(
                    at: CGPoint(x: x, y: y + (line.height - item.size.height) / 2),
                    proposal: ProposedViewSize(item.size))
                x += item.size.width + spacing
            }
            y += line.height + lineSpacing
        }
    }

    private func lines(of subviews: Subviews, within width: CGFloat) -> [Line] {
        var lines: [Line] = []
        var line = Line()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !line.items.isEmpty, line.width + spacing + size.width > width {
                lines.append(line)
                line = Line()
            }
            line.width = line.items.isEmpty ? size.width : line.width + spacing + size.width
            line.height = max(line.height, size.height)
            line.items.append(Item(index: index, size: size))
        }
        if !line.items.isEmpty { lines.append(line) }
        return lines
    }
}
