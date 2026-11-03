import SwiftUI

struct ClockView: View {
    @ObservedObject var module: ClockModule
    @ObservedObject var preferences: ModulePreferences<ClockPreferences>

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 时间口径统一 HH:mm(:ss)，日期统一 yyyy-MM-dd：不跟随系统语言，
            // 避免英文系统下出现 "Nov 3, 2026" / 12 小时制读数。
            Text(TimeFormat.string(module.date, style: preferences.value.showSeconds ? .time : .minuteTime))
                .font(.system(size: 34, weight: .medium, design: .rounded).monospacedDigit())
            HStack {
                Text("\(TimeFormat.string(module.date, style: .date)) \(TimeFormat.weekday(module.date))")
                Spacer()
                if preferences.value.showTimeZone {
                    Text(TimeZone.current.localizedName(for: .generic, locale: Locale(identifier: "zh_CN")) ?? TimeZone.current.identifier)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.05)))
    }
}
