import Foundation

/// 全项目统一的时间显示口径：日期 `yyyy-MM-dd`、日期时间 `yyyy-MM-dd HH:mm:ss`、时间 `HH:mm:ss`。
///
/// 刻意不用 `Date.FormatStyle` / `DateFormatter`：前者跟随系统语言与地区，
/// 会输出 "Nov 3, 2026" 这类英文月份，或在 12 小时制下变成 "4:57 PM"。
/// 这里固定公历取分量后自行拼装，任何系统语言下的读数都一致，
/// 也便于回归测试断言精确字符串（可注入时区，不受运行机器时区影响）。
enum TimeFormat {
    enum Style {
        /// `yyyy-MM-dd`：只表示年月日。
        case date
        /// `yyyy-MM-dd HH:mm:ss`：年月日 + 时分秒。
        case dateTime
        /// `HH:mm:ss`：只表示时分秒。
        case time
        /// `HH:mm`：时分秒口径的省略秒变体，供"隐藏秒数"开关使用。
        case minuteTime
    }

    /// 按口径格式化时刻；`timeZone` 默认当前时区，测试可注入固定时区。
    static func string(_ date: Date, style: Style, timeZone: TimeZone = .current) -> String {
        let parts = components(of: date, timeZone: timeZone)
        let year = parts.year ?? 0
        let month = parts.month ?? 0
        let day = parts.day ?? 0
        let hour = parts.hour ?? 0
        let minute = parts.minute ?? 0
        let second = parts.second ?? 0
        switch style {
        case .date:
            return "\(pad(year, width: 4))-\(pad(month))-\(pad(day))"
        case .dateTime:
            return "\(pad(year, width: 4))-\(pad(month))-\(pad(day)) \(pad(hour)):\(pad(minute)):\(pad(second))"
        case .time:
            return "\(pad(hour)):\(pad(minute)):\(pad(second))"
        case .minuteTime:
            return "\(pad(hour)):\(pad(minute))"
        }
    }

    /// 中文星期（周几）：`.dateTime.weekday(.wide)` 在英文系统下会输出 "Monday"，
    /// 这里固定中文短称，保证日期旁不出现英文月份 / 星期。
    static func weekday(_ date: Date, timeZone: TimeZone = .current) -> String {
        let index = components(of: date, timeZone: timeZone).weekday ?? 1
        let names = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
        return names[(index - 1 + names.count) % names.count]
    }

    /// 固定公历取分量：不用 `Calendar.current`，避免用户把系统日历设为佛历等导致年份偏移。
    private static func components(of date: Date, timeZone: TimeZone) -> DateComponents {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.dateComponents([.year, .month, .day, .hour, .minute, .second, .weekday], from: date)
    }

    private static func pad(_ value: Int, width: Int = 2) -> String {
        let sign = value < 0 ? "-" : ""
        let digits = String(abs(value))
        return sign + String(repeating: "0", count: max(0, width - digits.count)) + digits
    }
}
