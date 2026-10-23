import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SubscriptionQuotaSettingsView: View {
    @ObservedObject var module: SubscriptionQuotaModule
    @ObservedObject var preferences: ModulePreferences<SubscriptionQuotaPreferences>
    @State private var codexPath = ""
    @State private var editor: SubscriptionAccountEditorTarget?

    var body: some View {
        Group {
            Section("预览") {
                Toggle("演示模式（不连接已保存账号）", isOn: preferences.binding(for: \.demoMode))
                Text("演示使用离线示例。添加账号后关闭演示模式，即可显示真实额度。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("账号") {
                HStack {
                    Text("GLM 和 Codex 均可添加多个账号，别名可留空。")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Menu("添加账号") {
                        Button("GLM Coding Plan") { editor = .init(provider: .glm) }
                        Button("ChatGPT · Codex") { editor = .init(provider: .codex) }
                    }.fixedSize()
                }
                if preferences.value.accounts.isEmpty {
                    Text("尚未添加账号").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(preferences.value.accounts) { account in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(account.displayName(in: preferences.value.accounts)).fontWeight(.medium).lineLimit(1)
                                Text(account.provider.title + (account.provider == .codex ?
                                    (account.codexAuthStored ? " · 登录已独立保存" : " · 跟随本机登录，建议导入固定账号") : " · 独立密钥"))
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 4)
                            Toggle("启用账号", isOn: enabledBinding(account.id)).labelsHidden()
                                .toggleStyle(.switch).controlSize(.mini).help("启用此账号")
                            Button("编辑") { editor = .init(provider: account.provider, account: account) }
                            Button(role: .destructive) { module.removeAccount(account.id) } label: { Image(systemName: "trash") }
                                .help("移除此账号及本软件保存的凭据")
                        }
                        if let error = module.errors[account.id] {
                            Text(error.message(for: account.provider)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if let message = module.settingsMessage { Text(message).font(.caption).foregroundStyle(.secondary) }
            }
            Section("Codex CLI") {
                HStack {
                    TextField("可执行文件路径（留空自动查找）", text: $codexPath)
                        .onAppear { codexPath = preferences.value.codexExecutable }
                        .onSubmit { applyCodexPath() }
                    Button("应用路径") { applyCodexPath() }
                }
                Text("导入 auth.json 时先验证登录与额度接口，成功后按账号保存到本机钥匙串。后续查询不依赖原文件或 Codex 当前登录，token 刷新结果也会保存。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("刷新") {
                HStack {
                    Text("启用后每 5 分钟更新，单个账号失败不影响其他账号。")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("立即刷新") { module.refresh() }
                        .disabled(!module.active || preferences.value.demoMode || !module.refreshing.isEmpty)
                }
                if let error = preferences.saveError { Text(error).font(.caption).foregroundStyle(.red) }
            }
        }
        .sheet(item: $editor) { target in
            SubscriptionAccountEditor(module: module, provider: target.provider, account: target.account)
        }
    }

    private func enabledBinding(_ id: String) -> Binding<Bool> {
        Binding(get: { preferences.value.accounts.first { $0.id == id }?.enabled ?? false }, set: { value in
            preferences.update {
                if let index = $0.accounts.firstIndex(where: { $0.id == id }) { $0.accounts[index].enabled = value }
            }
        })
    }

    private func applyCodexPath() {
        preferences.update { $0.codexExecutable = codexPath.trimmingCharacters(in: .whitespacesAndNewlines) }
    }
}

private struct SubscriptionAccountEditorTarget: Identifiable {
    let id = UUID()
    var provider: SubscriptionProvider
    var account: SubscriptionAccount?
}

struct SubscriptionAccountEditor: View {
    @ObservedObject var module: SubscriptionQuotaModule
    let provider: SubscriptionProvider
    let original: SubscriptionAccount?
    @Environment(\.dismiss) private var dismiss
    @State private var account: SubscriptionAccount
    @State private var glmKey = ""
    @State private var authPath = ""

    init(module: SubscriptionQuotaModule, provider: SubscriptionProvider, account: SubscriptionAccount? = nil) {
        self.module = module
        self.provider = provider
        original = account
        _account = State(initialValue: account ?? SubscriptionAccount(provider: provider))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text((original == nil ? "添加 " : "编辑 ") + provider.title).font(.headline)
            TextField("账号别名（选填）", text: $account.alias)
                .textFieldStyle(.roundedBorder)
            Toggle("启用此账号", isOn: $account.enabled)
            if provider == .glm {
                SecureField(original == nil ? "Coding Plan 密钥" : "新密钥（留空保留已有密钥）", text: $glmKey)
                    .textFieldStyle(.roundedBorder)
                Text("每个账号的密钥独立保存在本机钥匙串，仅用于官方只读额度接口。")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                HStack {
                    TextField(original == nil ? "auth.json 文件路径，支持 ~/" : "新 auth.json 路径（留空保留已保存登录）", text: $authPath)
                        .textFieldStyle(.roundedBorder)
                    Button("选择…") { chooseAuthFile() }
                }
                Text(original?.codexAuthStored == false ?
                     "此旧版账号目前跟随本机登录。导入 auth.json 并验证后，即可独立保留此账号。" :
                     "验证通过后保存登录，原文件可移动或删除。切换 Codex 当前账号不会改变已保存的账号。仅支持 ChatGPT 订阅登录。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let message = module.settingsMessage {
                Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            HStack {
                if module.verifying { ProgressView().controlSize(.small); Text("验证中…").font(.caption) }
                Spacer()
                Button("取消") { module.cancelAccountVerification(); dismiss() }.keyboardShortcut(.cancelAction)
                Button(provider == .codex && (original == nil || !authPath.isEmpty) ? "验证并保存" : "保存账号") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(module.verifying || (original == nil && (provider == .glm ? glmKey : authPath).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
            }
        }
        .padding(24).frame(width: 520, height: 350)
        .onAppear { module.clearSettingsMessage() }
        .onDisappear { module.cancelAccountVerification() }
        .interactiveDismissDisabled(module.verifying)
    }

    private func chooseAuthFile() {
        let panel = NSOpenPanel()
        panel.title = "选择此账号的 Codex auth.json"
        panel.allowedContentTypes = [.json]
        panel.showsHiddenFiles = true
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url { authPath = url.path }
    }

    private func save() {
        account.alias = account.alias.trimmingCharacters(in: .whitespacesAndNewlines)
        if provider == .glm {
            if module.saveGLMAccount(account, key: glmKey) { glmKey = ""; dismiss() }
        } else {
            module.saveCodexAccount(account, authPath: authPath) { saved in if saved { dismiss() } }
        }
    }
}
