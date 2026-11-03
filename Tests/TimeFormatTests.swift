import Foundation
import XCTest

/// 时间显示口径回归：日期 `yyyy-MM-dd`、日期时间 `yyyy-MM-dd HH:mm:ss`、时间 `HH:mm:ss`。
/// 注入固定时区后字符串可精确断言，既锁住格式，也挡住"跟随系统语言"的写法
/// （英文系统会输出 "Nov 3, 2026" 或 12 小时制）。
final class TimeFormatTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    private let shanghai = TimeZone(identifier: "Asia/Shanghai")!

    private func date(_ year: Int, _ month: Int, _ day: Int,
                      _ hour: Int = 0, _ minute: Int = 0, _ second: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        return calendar.date(from: components)!
    }

    func testDateAndDateTimeUseFixedISOOrder() {
        let moment = date(2026, 11, 3, 16, 57, 24)
        XCTAssertEqual(TimeFormat.string(moment, style: .date, timeZone: utc), "2026-11-03")
        XCTAssertEqual(TimeFormat.string(moment, style: .dateTime, timeZone: utc), "2026-11-03 16:57:24")
    }

    func testZeroPaddingKeepsTwoDigits() {
        let moment = date(2026, 1, 2, 3, 4, 5)
        XCTAssertEqual(TimeFormat.string(moment, style: .dateTime, timeZone: utc), "2026-01-02 03:04:05")
        XCTAssertEqual(TimeFormat.string(moment, style: .time, timeZone: utc), "03:04:05")
        XCTAssertEqual(TimeFormat.string(moment, style: .minuteTime, timeZone: utc), "03:04")
    }

    func testTimeIs24HourEvenAtMidnight() {
        // 12 小时制语言环境下这里必须仍是 00:00:00，而不是 "12:00:00 AM"。
        XCTAssertEqual(TimeFormat.string(date(2026, 11, 3), style: .time, timeZone: utc), "00:00:00")
        XCTAssertEqual(TimeFormat.string(date(2026, 11, 3, 23, 59, 59), style: .time, timeZone: utc), "23:59:59")
    }

    func testTimeZoneShiftsHourWithoutChangingFormat() {
        let moment = date(2026, 6, 22)
        XCTAssertEqual(TimeFormat.string(moment, style: .dateTime, timeZone: utc), "2026-06-22 00:00:00")
        XCTAssertEqual(TimeFormat.string(moment, style: .dateTime, timeZone: shanghai), "2026-06-22 08:00:00")
    }

    func testWeekdayIsChineseShortName() {
        XCTAssertEqual(TimeFormat.weekday(date(2026, 11, 3), timeZone: utc), "周二")
        XCTAssertEqual(TimeFormat.weekday(date(2026, 11, 1), timeZone: utc), "周日")
        XCTAssertEqual(TimeFormat.weekday(date(2026, 11, 7), timeZone: utc), "周六")
    }

    func testYearBoundaryUsesLocalCalendarDateAndWeekday() {
        let moment = date(2025, 12, 31, 16, 4, 5)
        XCTAssertEqual(TimeFormat.string(moment, style: .dateTime, timeZone: utc), "2025-12-31 16:04:05")
        XCTAssertEqual(TimeFormat.string(moment, style: .dateTime, timeZone: shanghai), "2026-01-01 00:04:05")
        XCTAssertEqual(TimeFormat.string(moment, style: .date, timeZone: shanghai), "2026-01-01")
        XCTAssertEqual(TimeFormat.weekday(moment, timeZone: shanghai), "周四")
    }

    func testLeapDayAndDaylightSavingUseTimeZoneRules() {
        XCTAssertEqual(TimeFormat.string(date(2024, 2, 29), style: .date, timeZone: utc), "2024-02-29")
        let newYork = TimeZone(identifier: "America/New_York")!
        XCTAssertEqual(TimeFormat.string(date(2026, 3, 8, 6, 59, 59), style: .dateTime, timeZone: newYork),
                       "2026-03-08 01:59:59")
        XCTAssertEqual(TimeFormat.string(date(2026, 3, 8, 7), style: .dateTime, timeZone: newYork),
                       "2026-03-08 03:00:00")
    }
}
