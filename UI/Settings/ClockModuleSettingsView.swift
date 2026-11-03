import SwiftUI

struct ClockModuleSettingsView: View {
    @ObservedObject var preferences: ModulePreferences<ClockPreferences>

    var body: some View {
        Section("时钟") {
            Toggle("显示秒数", isOn: preferences.binding(for: \.showSeconds))
            Toggle("显示时区", isOn: preferences.binding(for: \.showTimeZone))
            Text("使用系统本地时间，时分秒统一 HH:mm:ss、日期统一 yyyy-MM-dd；在模块管理中启用后显示。")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let error = preferences.saveError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
    }
}
