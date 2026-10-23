import SwiftUI

struct ProcessModuleSettingsView: View {
    @ObservedObject var settings: SettingsStore

    var body: some View {
        Section("进程监控") {
            Picker("展示方式", selection: $settings.processDisplay) {
                Text("块状").tag("grid")
                Text("列表").tag("list")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 180, alignment: .leading)
            Toggle("显示 App 进程占用的端口", isOn: $settings.showAppProcesses)
            Toggle("显示脚本进程占用的端口（node / python / java 等）", isOn: $settings.showScriptProcesses)
            Text("列出当前用户所有监听 TCP 端口的进程（系统守护进程除外），可一键结束（SIGTERM）。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }


    }
}
