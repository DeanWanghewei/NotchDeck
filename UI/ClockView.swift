import SwiftUI

struct ClockView: View {
    @ObservedObject var module: ClockModule
    @ObservedObject var preferences: ModulePreferences<ClockPreferences>

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(module.date, format: preferences.value.showSeconds ?
                    .dateTime.hour().minute().second() : .dateTime.hour().minute())
                .font(.system(size: 34, weight: .medium, design: .rounded).monospacedDigit())
            HStack {
                Text(module.date, format: .dateTime.year().month().day().weekday(.wide))
                Spacer()
                if preferences.value.showTimeZone {
                    Text(TimeZone.current.localizedName(for: .generic, locale: .current) ?? TimeZone.current.identifier)
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
