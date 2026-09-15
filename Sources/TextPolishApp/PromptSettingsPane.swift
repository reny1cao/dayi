import PolishCore
import SwiftUI

struct PromptSettingsPane: View {
    let settings: PromptSettings
    @State private var system = ""
    @State private var user = ""
    @State private var sample = ""
    @State private var message: String?
    @State private var failed = false
    @State private var loaded = false

    private var validation: String? {
        do {
            _ = try PromptTemplate(systemPrompt: system, userPromptTemplate: user, sourceVersion: "preview")
            return nil
        } catch { return error.localizedDescription }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(settings.isCustom ? L10n.tr("当前使用本机自定义提示词") : L10n.tr("当前使用 Dayi 默认提示词"))
                .font(.headline)
            Text(L10n.tr("修改仅保存在本机，保存后用于下一次润色；正在处理的任务不受影响。"))
                .font(.caption).foregroundStyle(.secondary)
            editor(L10n.tr("系统提示词"), text: $system, height: 150)
            editor(L10n.tr("用户提示词"), text: $user, height: 80)
            Text(L10n.tr("{input} 会替换为待润色内容，必须且只能出现一次。"))
                .font(.caption).foregroundStyle(.secondary)
            if let validation { Text(validation).font(.caption).foregroundStyle(.red) }
            Divider()
            TextField(L10n.tr("输入示例，预览发给模型的用户消息"), text: $sample)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("prompt.previewInput")
            ScrollView {
                Text(preview).font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(height: 80)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
            Text(L10n.tr("预览不调用模型；上方系统提示词将作为另一条消息一同发送。"))
                .font(.caption).foregroundStyle(.secondary)
            if let failure = settings.failure { Text(failure).font(.caption).foregroundStyle(.red) }
            if let message {
                Text(message).font(.caption).foregroundStyle(failed ? Color.red : Color.secondary)
            }
            HStack {
                Button(L10n.tr("恢复默认内容")) {
                    do {
                        let template = try settings.bundled()
                        system = template.systemPrompt; user = template.userPromptTemplate
                        message = L10n.tr("默认内容已填入，保存后生效。")
                        failed = false
                    } catch { show(error) }
                }
                Button(L10n.tr("撤销未保存修改")) { load() }
                Spacer()
                Button(settings.isSaving ? L10n.tr("保存中…") : L10n.tr("保存并启用")) {
                    Task {
                        do {
                            try await settings.save(system: system, user: user)
                            message = L10n.tr("已保存，下一次润色生效。")
                            failed = false
                        } catch { show(error) }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(validation != nil || !settings.isReady)
            }
        }
        .padding(20)
        .disabled(settings.isSaving)
        .onAppear { if !loaded { load() } }
        .onChange(of: settings.isReady) { if !loaded { load() } }
    }

    private var preview: String {
        guard !sample.isEmpty, validation == nil,
              let template = try? PromptTemplate(systemPrompt: system, userPromptTemplate: user, sourceVersion: "preview"),
              let result = try? template.render(sample) else { return L10n.tr("输入示例后显示预览，不会发送网络请求。") }
        return result
    }

    private func editor(_ title: String, text: Binding<String>, height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline)
            TextEditor(text: text).font(.system(.body, design: .monospaced))
                .frame(height: height).border(Color.secondary.opacity(0.25))
                .accessibilityLabel(title)
        }
    }

    private func load() {
        do {
            let selection = try settings.selection()
            system = selection.template.systemPrompt; user = selection.template.userPromptTemplate
            loaded = settings.isReady
            message = nil; failed = false
        } catch { show(error) }
    }

    private func show(_ error: Error) { message = error.localizedDescription; failed = true }
}
