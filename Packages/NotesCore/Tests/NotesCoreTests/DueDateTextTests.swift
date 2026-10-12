import Foundation
import Testing

@testable import NotesCore

struct DueDateTextTests {
    private static func calendar(_ zone: String = "Asia/Shanghai") -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }

    /// 2026-10-12 是周一。
    private let calendar = DueDateTextTests.calendar()
    private func now(hour: Int = 9) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: hour))!
    }

    private func display(_ day: String, time: String? = nil, now: Date? = nil) -> DueDateDisplay? {
        DueDateText.display(for: DueDate(day: day, time: time), today: now ?? self.now(), calendar: calendar)
    }

    @Test func todayTomorrowYesterday() {
        #expect(display("2026-10-12") == DueDateDisplay(day: .today, time: nil, phase: .today))
        #expect(display("2026-10-13") == DueDateDisplay(day: .tomorrow, time: nil, phase: .upcoming))
        #expect(display("2026-10-11") == DueDateDisplay(day: .yesterday, time: nil, phase: .overdue))
    }

    @Test func weekdayWithinSixDays() {
        // 10-14 周三 = 4，10-18 周日 = 1
        #expect(display("2026-10-14")?.day == .weekday(4))
        #expect(display("2026-10-18")?.day == .weekday(1))
        #expect(display("2026-10-14")?.phase == .upcoming)
    }

    @Test func sevenDaysOutIsADate() {
        #expect(display("2026-10-19")?.day == .date(year: nil, month: 10, day: 19))
    }

    @Test func otherYearKeepsYear() {
        #expect(display("2027-01-05")?.day == .date(year: 2027, month: 1, day: 5))
        #expect(display("2025-12-31") == DueDateDisplay(day: .date(year: 2025, month: 12, day: 31), time: nil, phase: .overdue))
    }

    @Test func olderThanYesterdayIsOverdueDate() {
        #expect(display("2026-10-10") == DueDateDisplay(day: .date(year: nil, month: 10, day: 10), time: nil, phase: .overdue))
    }

    @Test func timeIsKept() {
        #expect(display("2026-10-12", time: "15:30")?.time == "15:30")
        #expect(display("2026-10-13", time: "09:00")?.time == "09:00")
    }

    /// 一天里的几点不影响「今天」。
    @Test func lateNightStillSameDay() {
        #expect(display("2026-10-12", now: now(hour: 23))?.phase == .today)
        #expect(display("2026-10-13", now: now(hour: 0))?.day == .tomorrow)
    }

    /// 同一时刻在不同时区的日历里，「今天」不同。
    @Test func followsCalendarTimeZone() {
        let instant = Date(timeIntervalSince1970: 1_791_800_000)  // 固定时刻
        let tokyo = DueDateTextTests.calendar("Asia/Tokyo")
        let la = DueDateTextTests.calendar("America/Los_Angeles")
        let comps = { (c: Calendar) in c.dateComponents([.year, .month, .day], from: instant) }
        let tokyoDay = comps(tokyo)
        let laDay = comps(la)
        let key = { (d: DateComponents) in String(format: "%04d-%02d-%02d", d.year!, d.month!, d.day!) }
        #expect(DueDateText.display(for: DueDate(day: key(tokyoDay)), today: instant, calendar: tokyo)?.phase == .today)
        #expect(DueDateText.display(for: DueDate(day: key(laDay)), today: instant, calendar: la)?.phase == .today)
    }

    /// 夏令时切换日前后，仍按日历日计算。
    @Test func acrossDaylightSavingChange() {
        let la = DueDateTextTests.calendar("America/Los_Angeles")
        let today = la.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 12))!  // 11-01 凌晨回拨
        #expect(DueDateText.display(for: DueDate(day: "2026-11-02"), today: today, calendar: la)?.day == .tomorrow)
        #expect(DueDateText.display(for: DueDate(day: "2026-10-31"), today: today, calendar: la)?.day == .yesterday)
    }

    @Test func invalidDayReturnsNil() {
        #expect(display("tomorrow") == nil)
        #expect(display("2026-10") == nil)
        #expect(display("") == nil)
        // 格式对但不是真实日期：不能被换算成别的日子（2026-02-30 → 3 月 2 日）
        #expect(display("2026-02-30") == nil)
        #expect(display("2026-13-01") == nil)
        #expect(display("2026-00-10") == nil)
        #expect(display("2026-10-32") == nil)
    }
}
