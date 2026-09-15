import Foundation
import PolishCore
import SwiftUI

extension ProviderPreset {
    /// The measured range as numbers. Parsed rather than stored twice: the catalogue keeps
    /// one string, and the column that sorts by latency needs the same string as a number.
    var measuredRange: ClosedRange<Double>? {
        guard let measured else { return nil }
        let bounds = measured.split(separator: "–").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        switch bounds.count {
        case 1: return bounds[0]...bounds[0]
        case 2 where bounds[0] <= bounds[1]: return bounds[0]...bounds[1]
        default: return nil
        }
    }

    /// The fastest measured request, for sorting. Nil sorts last, which is where the 39
    /// entries nobody has run belong.
    var measuredFloor: Double? { measuredRange?.lowerBound }

    /// Slow enough that a person would wonder whether the press registered. GLM-5.3 measured
    /// 19.3s at the tail (docs/status.md), and that is the whole reason this column exists.
    var hasLongTail: Bool { (measuredRange?.upperBound ?? 0) >= 10 }

    func matches(_ query: String) -> Bool {
        guard !query.isEmpty else { return true }
        if name.localizedCaseInsensitiveContains(query) { return true }
        if model.localizedCaseInsensitiveContains(query) { return true }
        return models.contains { $0.localizedCaseInsensitiveContains(query) }
    }
}

/// 更改… — the 42 presets as one searchable, sortable table.
///
/// They used to be a four-section menu, which at 42 items is a scroll rather than a choice.
/// A table can be searched and, more to the point, compared: the only three entries this
/// project has ever sent a request to are the ones with a number in the last column.
struct ProviderPicker: View {
    enum Scope: Hashable { case verified, all }

    let catalog: ProviderCatalog
    let current: ProviderPreset?
    let onChoose: (ProviderPreset) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var scope: Scope
    @State private var selection: ProviderPreset.ID?
    @State private var sortOrder = [KeyPathComparator(\ProviderPreset.measuredFloor, order: .forward)]

    init(catalog: ProviderCatalog, current: ProviderPreset?, onChoose: @escaping (ProviderPreset) -> Void) {
        self.catalog = catalog
        self.current = current
        self.onChoose = onChoose
        _selection = State(initialValue: current?.id)
        // Starting on 实测 hides an unverified provider that is already in use, so that one
        // case starts on the full list instead.
        _scope = State(initialValue: (current?.verified ?? true) ? .verified : .all)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            table
            Divider()
            footer
        }
        .frame(width: SettingsMetric.pickerWidth, height: SettingsMetric.pickerHeight)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: Metric.gap8) {
            Text(L10n.tr("选择服务商")).font(.body.weight(.semibold))
            Spacer(minLength: Metric.gap8)
            search
            Picker(L10n.tr("范围"), selection: $scope) {
                Text(L10n.tr("实测")).tag(Scope.verified)
                Text(L10n.format("全部 %@", String(describing: catalog.providers.count))).tag(Scope.all)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
        .padding(.horizontal, Metric.gap16)
        .padding(.vertical, Metric.gap12)
    }

    private var search: some View {
        HStack(spacing: Metric.gap4) {
            Image(systemName: "magnifyingglass")
                .imageScale(.small)
                .foregroundStyle(.secondary)
            TextField(L10n.tr("搜索名称或模型 id"), text: $query)
                .textFieldStyle(.plain)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.tr("清除搜索"))
            }
        }
        .padding(.horizontal, Metric.gap8)
        .frame(width: SettingsMetric.searchWidth, height: SettingsMetric.searchHeight)
        .background(
            RoundedRectangle(cornerRadius: Metric.radiusButton)
                .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.4))
        )
    }

    // MARK: - Table

    private var table: some View {
        Table(of: ProviderPreset.self, selection: $selection, sortOrder: $sortOrder) {
            TableColumn(L10n.tr("名称"), value: \.name) { preset in
                HStack(spacing: Metric.gap8) {
                    ProviderIcon.image(for: preset, in: catalog, size: SettingsMetric.logoSize)
                        .frame(width: SettingsMetric.logoSize, height: SettingsMetric.logoSize)
                    Text(preset.name).lineLimit(1)
                }
                .opacity(preset.verified ? 1 : SettingsMetric.unverifiedOpacity)
            }
            .width(SettingsMetric.nameColumnWidth)

            TableColumn(L10n.tr("默认模型"), value: \.model) { preset in
                Text(preset.model)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                    .opacity(preset.verified ? 1 : SettingsMetric.unverifiedOpacity)
            }
            .width(min: SettingsMetric.modelColumnMinWidth)

            TableColumn(L10n.tr("类别"), value: \.category) { preset in
                Text(L10n.tr(catalog.categories[preset.category] ?? preset.category))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .width(SettingsMetric.categoryColumnWidth)

            TableColumn(L10n.tr("实测耗时"), sortUsing: KeyPathComparator(\ProviderPreset.measuredFloor)) { preset in
                latency(preset)
            }
            .width(SettingsMetric.latencyColumnWidth)
        } rows: {
            Section {
                ForEach(verified) { TableRow($0) }
            }
            if !unverified.isEmpty {
                Section(L10n.tr("未实测 · 地址与参数以服务方文档为准")) {
                    ForEach(unverified) { TableRow($0) }
                }
            }
        }
        .tableStyle(.inset)
    }

    /// A long tail is worth marking, but the mark is a glyph: an orange measurement on
    /// `textBackgroundColor` is exactly the body-text contrast the design system refuses, and
    /// the shape reads before the colour for anyone who cannot separate the two.
    @ViewBuilder private func latency(_ preset: ProviderPreset) -> some View {
        if let measured = preset.measured {
            HStack(spacing: Metric.gap4) {
                if preset.hasLongTail {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .filledGlyph(.orange)
                        .imageScale(.small)
                        .accessibilityLabel(L10n.tr("尾延迟大"))
                }
                Text(measured + "s")
                    .font(.system(.body, design: .monospaced))
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .help(help(for: preset))
        } else {
            Text("—")
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private func help(for preset: ProviderPreset) -> String {
        guard preset.hasLongTail, let range = preset.measuredRange else { return L10n.tr(preset.note) }
        return L10n.tr("尾延迟大：最慢一次约 ") + String(format: "%.1f", range.upperBound) + L10n.tr(" 秒 · ") + L10n.tr(preset.note)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(alignment: .top, spacing: Metric.gap8) {
            VStack(alignment: .leading, spacing: 0) {
                (Text(L10n.tr("目录来自 CC Switch "))
                    + Text(catalog.source.commit).font(.system(.caption, design: .monospaced))
                    + Text("（\(catalog.source.license)）"))
                Text(L10n.format("%@ 条中 %@ 条从未发过请求", String(describing: catalog.providers.count), String(describing: neverRun)))
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
            Spacer(minLength: Metric.gap8)
            Button(L10n.tr("取消"), role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(L10n.tr("选用")) { choose() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(selected == nil)
        }
        .padding(.horizontal, Metric.gap16)
        .padding(.vertical, Metric.gap12)
    }

    // MARK: - Data

    private var order: [KeyPathComparator<ProviderPreset>] {
        // Name breaks ties so the 39 rows with no measurement keep one stable order.
        sortOrder + [KeyPathComparator(\ProviderPreset.name)]
    }

    private var matching: [ProviderPreset] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return catalog.providers.filter { $0.matches(text) }
    }

    /// Measured entries stay on top whatever the sort is: three rows that were actually run
    /// are a different kind of answer from thirty-nine that were transcribed.
    private var verified: [ProviderPreset] {
        matching.filter(\.verified).sorted(using: order)
    }

    private var unverified: [ProviderPreset] {
        guard scope == .all else { return [] }
        return matching.filter { !$0.verified }.sorted(using: order)
    }

    private var neverRun: Int { catalog.providers.filter { !$0.verified }.count }

    private var selected: ProviderPreset? {
        guard let selection else { return nil }
        return catalog.providers.first { $0.id == selection }
    }

    private func choose() {
        guard let selected else { return }
        onChoose(selected)
        dismiss()
    }
}
