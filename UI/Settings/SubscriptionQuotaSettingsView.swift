import SwiftUI

struct SubscriptionQuotaSettingsView: View {
    @ObservedObject var module: SubscriptionQuotaModule
    @ObservedObject var preferences: ModulePreferences<SubscriptionQuotaPreferences>
    @State private var glmKey = ""
    @State private var codexPath = ""

    var body: some View {
        Section("预览") {
            Toggle("演示模式（不连接账号）", isOn: preferences.binding(for: \.demoMode))
            Text("演示数据只用于查看效果。真实查询需关闭演示模式，并在模块管理中启用「订阅额度」。")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("GLM Coding Plan") {
            SecureField("Coding Plan 密钥", text: $glmKey)
            HStack {
                Button("保存并连接") { if module.saveGLMKey(glmKey) { glmKey = "" } }
                    .disabled(glmKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if preferences.value.glmEnabled {
                    Button("移除密钥", role: .destructive) { module.removeGLMKey() }
                }
                Spacer()
                Link("官方用量页", destination: SubscriptionProvider.glm.usageURL)
            }
            Text("密钥保存在本机钥匙串，仅发送至 open.bigmodel.cn 的只读用量接口。此处查询订阅额度，不能使用 API 现金余额替代。")
                .font(.caption).foregroundStyle(.secondary)
            if let message = module.settingsMessage { Text(message).font(.caption).foregroundStyle(.secondary) }
        }
        Section("ChatGPT · Codex") {
            Toggle("使用本机 Codex 的 ChatGPT 登录", isOn: preferences.binding(for: \.codexEnabled))
            if preferences.value.codexEnabled {
                HStack {
                    TextField("Codex CLI 路径（留空自动查找）", text: $codexPath)
                        .onAppear { codexPath = preferences.value.codexExecutable }
                        .onSubmit { applyCodexPath() }
                    Button("应用路径") { applyCodexPath() }
                }
            }
            Text("通过 Codex CLI 的只读额度协议查询。需已用 ChatGPT 账号登录；API Key 模式不提供订阅额度。不读取浏览器 Cookie，不修改已有登录。")
                .font(.caption).foregroundStyle(.secondary)
            Link("官方用量页", destination: SubscriptionProvider.codex.usageURL)
        }
        Section("刷新") {
            HStack {
                Text("启用后每 5 分钟更新；展开面板时按需刷新。")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("立即刷新") { module.refresh() }
                    .disabled(!module.active || preferences.value.demoMode || !module.refreshing.isEmpty)
            }
            ForEach(SubscriptionProvider.allCases) { provider in
                if let error = module.errors[provider] {
                    Text("\(provider.title)：\(error.message(for: provider))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let error = preferences.saveError { Text(error).font(.caption).foregroundStyle(.red) }
        }
    }

    private func applyCodexPath() {
        preferences.update { $0.codexExecutable = codexPath.trimmingCharacters(in: .whitespacesAndNewlines) }
    }
}
