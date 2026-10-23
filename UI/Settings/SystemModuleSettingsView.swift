import SwiftUI

struct SystemModuleSettingsView: View {
    @ObservedObject var settings: SettingsStore

    var body: some View {
        Section("系统监控显示") {
            Toggle("CPU 近 15 分钟走势图", isOn: $settings.showCPUHeatmap)
            Toggle("交换内存（swap）", isOn: $settings.showSwap)
            Toggle("电池（电量 / 剩余时间 / 容量 / 循环次数）", isOn: $settings.showBattery)
            Toggle("热压力警示（系统过热降速时提示）", isOn: $settings.showThermalPressure)
            HStack {
                Toggle("风扇转速", isOn: .constant(false))
                    .disabled(true)
                Text("此系统不提供")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            HStack {
                Toggle("GPU 使用率", isOn: .constant(false))
                    .disabled(true)
                Text("此系统不提供")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Text("GPU 与风扇需要系统提供的统计接口，当前 macOS 版本已移除，相关选项暂不可用。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
