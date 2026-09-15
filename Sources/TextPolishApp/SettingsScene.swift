import AppKit
import Observation
import PolishCore
import PolishStore
import ServiceManagement
import SwiftUI

/// Keys shared with the app scene. `MenuBarExtra(isInserted:)` reads the same default the
/// 通用 toggle writes, which is the only way that switch can actually remove the icon.
enum SettingsDefaults {
    static let menuBarVisible = "menuBar.visible"
}

/// The right-aligned label of a settings row.
struct SettingsLabel: View {
    let title: String
    var width: CGFloat = SettingsMetric.labelWidth

    init(_ title: String, width: CGFloat = SettingsMetric.labelWidth) {
        self.title = title
        self.width = width
    }

    var body: some View {
        Text(title).frame(width: width, alignment: .trailing)
    }
}

/// Which tab the Settings window opens on. `openSettings()` cannot say, and the inspector's
/// 检查模型设置 action means one specific tab — so the caller sets this first.
@MainActor @Observable
final class SettingsRoute {
    static let shared = SettingsRoute()
    var tab: SettingsScene.Tab = .general
    func show(_ tab: SettingsScene.Tab) { self.tab = tab }
}

/// Settings ▸ 通用 · 模型 · 历史 (⌘,). Configuration is not activity: none of this belongs in
/// the window a person opens to rescue a result.
struct SettingsScene: View {
    enum Tab: String, Hashable, CaseIterable {
        case general, model, prompt, history
    }

    let model: AppModel
    @Bindable var route = SettingsRoute.shared

    var body: some View {
        TabView(selection: $route.tab) {
            GeneralSettingsPane(model: model)
                .tabItem { Label(L10n.tr("通用"), systemImage: "gearshape") }
                .tag(Tab.general)
            ModelSettingsPane(model: model)
                .tabItem { Label(L10n.tr("模型"), systemImage: "cloud") }
                .tag(Tab.model)
            HistorySettingsPane(model: model)
                .tabItem { Label(L10n.tr("历史"), systemImage: "clock") }
                .tag(Tab.history)
            PromptSettingsPane(settings: model.prompts)
                .tabItem { Label(L10n.tr("提示词"), systemImage: "text.alignleft") }
                .tag(Tab.prompt)
        }
        .frame(width: Metric.settingsWidth)
    }
}

// MARK: - 通用

/// The two global shortcuts, the permission they depend on, and whether the app is resident.
/// Everything here is a precondition for a keypress in another application.
struct GeneralSettingsPane: View {
    let model: AppModel
    var bindings: HotKeyBindings = .shared

    @State private var launchesAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginFailure: String?
    @State private var language = InterfaceLanguage.load()

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Metric.gap12, verticalSpacing: Metric.gap12) {
            GridRow {
                SettingsLabel(L10n.tr("语言"), width: SettingsMetric.wideLabelWidth)
                VStack(alignment: .leading, spacing: Metric.gap4) {
                    Picker(L10n.tr("语言"), selection: $language) {
                        ForEach(InterfaceLanguage.allCases) { choice in
                            Text(choice.title).tag(choice)
                        }
                    }
                    .labelsHidden()
                    .onChange(of: language) { _, value in value.save() }
                    Text(L10n.tr("下次启动达意时生效。界面语言不改变润色结果的语言。"))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            ForEach(HotKeyBindings.Role.allCases) { role in
                GridRow {
                    SettingsLabel(role.title, width: SettingsMetric.wideLabelWidth)
                    HStack(spacing: Metric.gap8) {
                        HotKeyRecorder(role: role, bindings: bindings)
                        Text(role.note).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if let warning = bindings.conflict ?? model.hotKeyFailure {
                GridRow {
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    warningLine(warning)
                }
            }
            GridRow {
                SettingsLabel(L10n.tr("辅助功能"), width: SettingsMetric.wideLabelWidth)
                HStack(spacing: Metric.gap8) {
                    Image(systemName: model.accessibilityTrusted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .filledGlyph(model.accessibilityTrusted ? AnyShapeStyle(.green) : AnyShapeStyle(.orange))
                    Text(model.accessibilityTrusted ? L10n.tr("已授权") : L10n.tr("未授权"))
                    Button(L10n.tr("在系统设置中查看")) { model.openAccessibilitySettings() }
                }
            }
            GridRow {
                SettingsLabel(L10n.tr("菜单栏"), width: SettingsMetric.wideLabelWidth)
                Toggle(L10n.tr("常驻显示状态图标"), isOn: Binding(get: { model.menuBarVisible },
                                                    set: { model.menuBarVisible = $0 }))
                    .toggleStyle(.switch)
            }
            if !model.menuBarVisible {
                GridRow {
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    Text(L10n.format("图标关掉后 %@ 照常工作，但设置只能从活动窗口打开。", String(describing: bindings.polish.display)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            GridRow {
                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                Toggle(L10n.tr("登录时启动"), isOn: Binding(get: { launchesAtLogin }, set: { setLaunchesAtLogin($0) }))
                    .toggleStyle(.switch)
            }
            if let loginFailure {
                GridRow {
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    warningLine(loginFailure)
                }
            }
        }
        .padding(.horizontal, Metric.gap20)
        .padding(.vertical, Metric.gap20)
        // 620 is the window's width and is stated once, on the `TabView`. A pane fills the
        // content area the tab bar leaves it; restating 620 here would push its own padding
        // past that edge — which is where the 模型 pane's right-aligned 保存并启用 sits.
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func warningLine(_ text: String) -> some View {
        Label {
            Text(text).textSelection(.enabled)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .filledGlyph(.orange)
        }
        .font(.caption)
    }

    /// The switch reports what the system says afterwards, not what was asked for: a login
    /// item that silently failed to register is a promise the app cannot keep.
    private func setLaunchesAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginFailure = nil
        } catch {
            loginFailure = L10n.tr("登录项未能更改：") + error.localizedDescription
        }
        launchesAtLogin = SMAppService.mainApp.status == .enabled
    }
}

// MARK: - 模型

/// Where the model is chosen. Four rows, because four is what a person changes; the six
/// fields that map onto request parameters are behind 高级, prefilled from the preset.
struct ModelSettingsPane: View {
    /// The result of the last 测试 or 保存, which is what the card under the form shows.
    struct TestOutcome: Equatable {
        let passed: Bool
        let headline: String
        /// Model id and the first characters that came back — data, so it is monospaced.
        let detail: String
    }

    let model: AppModel

    @State private var editingID: UUID?
    @State private var credentialEndpoint = ""
    @State private var fetchedModels: [AvailableModel] = []
    @State private var modelQuery = ""
    @State private var modelPicker = false
    @State private var fetching = false
    @State private var listMessage: String?
    @State private var listTask: Task<Void, Never>?
    @State private var listGeneration = UUID()
    @State private var draft = ModelProfile()
    @State private var apiKey = ""
    @State private var chosen: ProviderPreset?
    @State private var advanced = false
    @State private var picking = false
    @State private var testing = false
    @State private var saving = false
    @State private var outcome: TestOutcome?
    @State private var loaded = false
    private let catalog = try? ProviderCatalog.bundled()

    var body: some View {
        VStack(spacing: 0) {
            form.disabled(testing || saving)
            Divider()
            toolbar
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { load() }
        .onChange(of: model.settings.source) { load(force: true) }
        .onChange(of: draft.endpoint) {
            if credentialEndpoint != draft.endpoint { apiKey = "" }
            invalidateModels()
        }
        .onChange(of: apiKey) { credentialEndpoint = draft.endpoint; invalidateModels() }
        .onDisappear { invalidateModels() }
        .sheet(isPresented: $picking) { picker }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: Metric.gap12) {
            if !model.settings.profiles.isEmpty {
                HStack {
                    Menu(L10n.tr("已保存的配置")) {
                        ForEach(model.settings.profiles) { saved in
                            Button(saved.profile.label + (saved.id == model.settings.activeID ? " ✓" : "")) {
                                edit(saved.profile, key: model.settings.key(for: saved), id: saved.id)
                            }
                        }
                    }
                    Text(L10n.tr("选择后可编辑，保存并启用后切换"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let error = model.settings.persistenceError { Text(error).foregroundStyle(.red) }
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Metric.gap12, verticalSpacing: Metric.gap12) {
                GridRow {
                    SettingsLabel(L10n.tr("服务商"))
                    HStack(spacing: Metric.gap8) {
                        providerPill
                        Button(L10n.tr("从目录添加…")) { picking = true }.disabled(catalog == nil)
                        Button(L10n.tr("添加自定义服务商")) {
                            edit(ModelProfile(reasoningEffort: ""), key: "", id: nil)
                            advanced = true
                        }
                    }
                }
                GridRow {
                    SettingsLabel(L10n.tr("模型"))
                    HStack(spacing: Metric.gap8) {
                        TextField(L10n.tr("模型 id"), text: $draft.model)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                            .frame(width: SettingsMetric.fieldWidth)
                            .accessibilityLabel(L10n.tr("模型 id"))
                        Button(fetching ? L10n.tr("获取中…") : L10n.tr("刷新模型")) { fetchModels() }
                            .disabled(fetching || draft.endpoint.isEmpty || apiKey.isEmpty)
                        Button(L10n.tr("选择模型…")) { modelPicker = true }
                            .disabled(fetchedModels.isEmpty)
                            .popover(isPresented: $modelPicker) {
                                VStack(alignment: .leading) {
                                    TextField(L10n.tr("搜索模型 ID 或名称"), text: $modelQuery)
                                    List(fetchedModels.filter { modelQuery.isEmpty || $0.id.localizedCaseInsensitiveContains(modelQuery) || $0.name.localizedCaseInsensitiveContains(modelQuery) }) { item in
                                        Button {
                                            draft.model = item.id
                                            modelPicker = false
                                        } label: {
                                            VStack(alignment: .leading) {
                                                Text(item.id).font(.system(.body, design: .monospaced))
                                                if item.name != item.id { Text(item.name).font(.caption) }
                                            }
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                        }.buttonStyle(.plain)
                                    }
                                }.padding().frame(width: 420, height: 320)
                            }
                    }
                }
                GridRow {
                    SettingsLabel("API Key")
                    HStack(spacing: Metric.gap8) {
                        SecureField("sk-…", text: $apiKey)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: SettingsMetric.fieldWidth)
                            .accessibilityLabel("API Key")
                        Label {
                            Text(keyNote)
                        } icon: {
                            Image(systemName: "lock.shield")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            }
            Text(providerNote).font(.caption).foregroundStyle(.secondary)
            Text(listMessage ?? L10n.tr("可刷新在线模型列表，也可手动输入 ID；列表不代表已通过润色测试。"))
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            DisclosureGroup(isExpanded: $advanced) {
                advancedFields
            } label: {
                HStack(spacing: Metric.gap8) {
                    Text(L10n.tr("高级")).font(.body.weight(.medium))
                    Text(advancedNote).font(.caption).foregroundStyle(.secondary)
                }
            }
            if let outcome { card(outcome) }
        }
        .padding(.horizontal, Metric.gap20)
        .padding(.top, Metric.gap20)
        .padding(.bottom, Metric.gap16)
    }

    private var providerPill: some View {
        HStack(spacing: Metric.gap8) {
            if let chosen, let catalog {
                ProviderIcon.image(for: chosen, in: catalog, size: SettingsMetric.pillLogoSize)
                    .frame(width: SettingsMetric.pillLogoSize, height: SettingsMetric.pillLogoSize)
                Text(chosen.name).font(.body.weight(.medium))
                if chosen.verified {
                    // The catalogue's one earned mark: this endpoint completed a real polish.
                    Image(systemName: "checkmark.circle.fill")
                        .imageScale(.small)
                        .filledGlyph(Color.accentColor)
                        .accessibilityLabel(L10n.tr("已实测"))
                }
            } else {
                Image(systemName: "cloud").foregroundStyle(.secondary)
                Text(draft.label.isEmpty ? L10n.tr("未选择服务商") : draft.label)
            }
        }
        .padding(.horizontal, Metric.gap8)
        .padding(.vertical, Metric.gap4)
        .background(
            RoundedRectangle(cornerRadius: Metric.radiusButton)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Metric.radiusButton)
                .strokeBorder(Color(nsColor: .separatorColor))
        )
    }

    private var advancedFields: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Metric.gap12, verticalSpacing: Metric.gap12) {
            GridRow {
                SettingsLabel("thinking")
                VStack(alignment: .leading, spacing: Metric.gap4) {
                    Picker("thinking", selection: $draft.thinking) {
                        Text(L10n.tr("由服务决定")).tag(ModelProfile.ThinkingMode.auto)
                        Text(L10n.tr("关闭思考")).tag(ModelProfile.ThinkingMode.disabled)
                    }
                    .labelsHidden()
                    .fixedSize()
                    Text(thinkingNote).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            GridRow {
                SettingsLabel("reasoning_effort")
                TextField(L10n.tr("空为不发"), text: $draft.reasoningEffort)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .frame(width: SettingsMetric.fieldWidth)
                    .accessibilityLabel("reasoning_effort")
            }
            GridRow {
                SettingsLabel(L10n.tr("额外参数"))
                TextField("{\"temperature\": 0.3}", text: $draft.extraParameters)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .frame(width: SettingsMetric.wideFieldWidth)
                    .accessibilityLabel(L10n.tr("额外参数 JSON"))
            }
            GridRow {
                SettingsLabel(L10n.tr("显示名称"))
                TextField(L10n.tr("默认为模型 id"), text: $draft.name)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: SettingsMetric.fieldWidth)
                    .accessibilityLabel(L10n.tr("显示名称"))
            }
            GridRow {
                SettingsLabel(L10n.tr("地址"))
                TextField("https://…/chat/completions", text: $draft.endpoint)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .frame(width: SettingsMetric.wideFieldWidth)
                    .accessibilityLabel(L10n.tr("Chat Completions 地址"))
            }
        }
        .padding(.top, Metric.gap8)
    }

    private func card(_ outcome: TestOutcome) -> some View {
        HStack(alignment: .top, spacing: Metric.gap12) {
            Image(systemName: outcome.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                .imageScale(.large)
                .filledGlyph(outcome.passed ? AnyShapeStyle(.green) : AnyShapeStyle(.red))
            VStack(alignment: .leading, spacing: Metric.gap4) {
                Text(outcome.headline)
                Text(outcome.detail)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Metric.gap12)
        .padding(.vertical, Metric.gap8)
        .background(
            RoundedRectangle(cornerRadius: Metric.radiusSelection)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Metric.radiusSelection)
                .strokeBorder(Color(nsColor: .separatorColor))
        )
    }

    private var toolbar: some View {
        HStack(spacing: Metric.gap8) {
            Text(L10n.format("保存后下一次按 %@ 起生效，不用重启", String(describing: HotKeyBindings.shared.polish.display)))
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: Metric.gap8)
            Button(testing ? L10n.tr("测试中…") : L10n.tr("用真实请求测试")) { test() }
                .disabled(testing || saving || !isComplete)
            Button(L10n.tr("保存并启用")) { save() }
                .buttonStyle(.borderedProminent)
                .disabled(testing || saving || !isComplete)
        }
        .padding(.horizontal, Metric.gap20)
        .padding(.vertical, Metric.gap12)
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    @ViewBuilder private var picker: some View {
        if let catalog {
            ProviderPicker(catalog: catalog, current: chosen) { preset in
                edit(preset.profile, key: "", id: nil)
            }
        }
    }

    // MARK: - Copy

    /// What this project knows about the chosen provider, which for 39 of 42 entries is that
    /// nobody has ever sent them a request.
    private var providerNote: String {
        guard let chosen else { return L10n.tr("自定义服务商使用 OpenAI Chat Completions 兼容协议") }
        guard chosen.verified else { return L10n.tr("未实测 · 地址与参数以服务方文档为准") }
        let measured = chosen.measured.map { L10n.format("%@ 秒", String(describing: $0)) }
        return [L10n.tr(chosen.note), measured].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private var keyNote: String {
        model.settings.source == .saved && !apiKey.isEmpty ? L10n.tr("存在钥匙串") : L10n.tr("保存时存进钥匙串")
    }

    private var advancedNote: String {
        guard let chosen else { return L10n.tr("思考控制、额外参数") }
        return L10n.format("思考控制、额外参数 · 已按 %@ 预填", String(describing: chosen.name))
    }

    /// The two switches are not interchangeable and the reason is measured, not editorial:
    /// docs/status.md:135 records which field each vendor actually honours.
    private var thinkingNote: String {
        switch draft.thinking {
        case .disabled: L10n.tr("DeepSeek 与 Kimi 只认 thinking: {type: disabled}；它们收下 reasoning_effort 但照常思考。")
        case .auto: L10n.tr("GLM-5.3 关不掉思考，只认 reasoning_effort: low；两个字段可以同时发，各家只取自己认的那个。")
        }
    }

    private var otherModels: [String] {
        chosen?.models.filter { $0 != draft.model } ?? []
    }

    private var isComplete: Bool {
        !draft.endpoint.trimmingCharacters(in: .whitespaces).isEmpty
            && !draft.model.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: - Actions

    private func load(force: Bool = false) {
        guard force || !loaded else { return }
        edit(model.settings.profile, key: model.settings.apiKey, id: model.settings.activeID)
        loaded = true
    }

    private func edit(_ profile: ModelProfile, key: String, id: UUID?) {
        invalidateModels()
        credentialEndpoint = profile.endpoint
        draft = profile
        apiKey = key
        editingID = id
        chosen = catalog?.preset(matching: profile)
        outcome = nil
    }

    private func invalidateModels() {
        listTask?.cancel()
        listGeneration = UUID()
        fetchedModels = []
        listMessage = nil
        fetching = false
        modelQuery = ""
    }

    private func fetchModels() {
        invalidateModels()
        let generation = listGeneration
        let endpoint = draft.endpoint
        let key = apiKey
        fetching = true
        listTask = Task {
            do {
                let models = try await ModelDirectory().models(endpoint: endpoint, apiKey: key)
                guard !Task.isCancelled, generation == listGeneration else { return }
                fetchedModels = models
                listMessage = models.isEmpty ? L10n.tr("服务商没有返回可用模型；可手动输入 ID。") : L10n.tr("模型列表已更新；选择后请用真实请求测试。")
                modelPicker = !models.isEmpty
            } catch {
                guard !Task.isCancelled, generation == listGeneration else { return }
                listMessage = error.localizedDescription
            }
            fetching = false
        }
    }

    /// One real request with the unsaved values, so a wrong key or a rejected parameter shows
    /// up here rather than on the next press.
    private func test() {
        testing = true
        outcome = nil
        let candidate = draft
        let key = apiKey
        let candidateID = editingID
        Task {
            do {
                let (completion, elapsed) = try await model.settings.probe(candidate, apiKey: key)
                guard draft == candidate, apiKey == key, editingID == candidateID else { testing = false; return }
                let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
                outcome = TestOutcome(passed: true,
                                  headline: String(format: L10n.tr("测试通过 · %.1f 秒"), seconds),
                                  detail: completion.model + " · " + String(completion.text.prefix(40)))
            } catch {
                outcome = TestOutcome(passed: false, headline: L10n.tr("测试失败"), detail: error.localizedDescription)
            }
            testing = false
        }
    }

    private func save() {
        saving = true
        let candidate = draft
        let key = apiKey
        let candidateID = editingID
        Task {
            do {
                try await model.settings.save(candidate, apiKey: key, id: candidateID)
                editingID = model.settings.activeID
                outcome = TestOutcome(passed: true, headline: L10n.tr("已保存并启用"),
                                  detail: candidate.model + L10n.format(" · 下一次按 %@ 起生效", String(describing: HotKeyBindings.shared.polish.display)))
            } catch {
                outcome = TestOutcome(passed: false, headline: L10n.tr("未保存"), detail: error.localizedDescription)
            }
            saving = false
        }
    }
}
