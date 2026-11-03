import AppKit
import SwiftUI

struct SubscriptionQuotaSettingsView: View {
    @ObservedObject var module: SubscriptionQuotaModule
    @ObservedObject var preferences: ModulePreferences<SubscriptionQuotaPreferences>
    @State private var codexPath = ""
    @State private var editor: SubscriptionAccountEditorTarget?

    var body: some View {
        Group {
            Section("额度提醒") {
                NotificationPermissionToggle("启用额度消息提醒", isOn: preferences.binding(for: \.notificationsEnabled))
                Stepper("已用达到 \(preferences.value.effectiveNotificationThreshold)% 时提醒",
                        value: preferences.binding(for: \.notificationThreshold), in: 1...100)
                Text("按账号和额度周期分别提醒；同一周期只提醒一次。通知显示受系统通知设置与专注模式影响。")
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
                                    (account.codexAuthStored ? " · 登录已独立保存" : " · 跟随本机登录，请粘贴 JSON 固定账号") : " · 独立密钥"))
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
                Text("粘贴登录 JSON 后先验证格式与额度接口，成功后按账号加密保存到应用 Data 目录。后续查询不依赖 Codex 当前登录，token 刷新结果也会保存。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("GLM 解析脚本") {
                if let version = module.scriptVersion {
                    Text("市场脚本 v\(version)").fontWeight(.medium)
                } else {
                    Text("未安装市场脚本，使用内置解析").foregroundStyle(.secondary)
                }
                if module.scriptDegraded {
                    Label("脚本解析失败，已回退内置解析；可在插件市场重新更新脚本", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Toggle("停用脚本，使用内置解析", isOn: preferences.binding(for: \.glmScriptDisabled))
                Text("脚本来自插件市场并在应用内更新，无需重装。它运行在无网络、无文件访问的沙箱中，仅负责响应解析；密钥仍由本应用加密保管。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("刷新") {
                HStack {
                    Text("启用后每 5 分钟更新，单个账号失败不影响其他账号。")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("立即刷新") { module.refresh() }
                        .disabled(!module.active || !module.refreshing.isEmpty)
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
    @State private var authJSON = ""

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
                Text("密钥按账号加密保存在应用 Data 目录，不访问钥匙串。旧版账号请重新填写密钥或粘贴登录 JSON。")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text(original == nil ? "账号登录 JSON" : "新的账号登录 JSON（留空保留已有登录）")
                    .font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $authJSON)
                    .font(.system(size: 11, design: .monospaced))
                    .autocorrectionDisabled()
                    .frame(height: 116)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                    .accessibilityLabel("粘贴完整的 Codex 登录 JSON")
                    .disabled(module.verifying)
                Text("粘贴完整的 Codex 登录 JSON（包含 tokens.access_token）。仅支持 ChatGPT 订阅登录，不支持 API Key；验证成功后加密保存，切换账号不受影响。")
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
                Button(provider == .codex && (original == nil || !authJSON.isEmpty) ? "验证并保存" : "保存账号") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(module.verifying || (original == nil && (provider == .glm ? glmKey : authJSON).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
            }
        }
        .padding(24).frame(width: 520, height: provider == .codex ? 460 : 350)
        .onAppear { module.clearSettingsMessage() }
        .onDisappear { module.cancelAccountVerification(); authJSON = "" }
        .interactiveDismissDisabled(module.verifying)
    }

    private func save() {
        account.alias = account.alias.trimmingCharacters(in: .whitespacesAndNewlines)
        if provider == .glm {
            if module.saveGLMAccount(account, key: glmKey) { glmKey = ""; dismiss() }
        } else {
            module.saveCodexAccount(account, authJSON: authJSON) { saved in if saved { authJSON = ""; dismiss() } }
        }
    }
}
