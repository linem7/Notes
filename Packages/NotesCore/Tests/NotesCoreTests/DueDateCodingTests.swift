import Foundation
import Testing

@testable import NotesCore

struct DueDateCodingTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }

    @Test func dateOnly() {
        let date = calendar.date(from: DateComponents(year: 2026, month: 3, day: 5, hour: 18, minute: 40))!
        #expect(DueDate(date: date, includesTime: false, calendar: calendar) == DueDate(day: "2026-03-05"))
    }

    @Test func dateWithTimeIsZeroPadded() {
        let date = calendar.date(from: DateComponents(year: 2026, month: 3, day: 5, hour: 7, minute: 5))!
        #expect(DueDate(date: date, includesTime: true, calendar: calendar) == DueDate(day: "2026-03-05", time: "07:05"))
    }

    @Test func roundTrip() {
        let due = DueDate(day: "2026-12-31", time: "23:59")
        let date = due.date(calendar: calendar)!
        #expect(DueDate(date: date, includesTime: true, calendar: calendar) == due)
    }

    @Test func missingTimeMeansMidnight() {
        let date = DueDate(day: "2026-10-12").date(calendar: calendar)!
        let c = calendar.dateComponents([.hour, .minute], from: date)
        #expect(c.hour == 0 && c.minute == 0)
    }

    @Test func invalidValuesReturnNil() {
        #expect(DueDate(day: "soon").date(calendar: calendar) == nil)
        #expect(DueDate(day: "2026-10-12", time: "noon").date(calendar: calendar) == nil)
    }
}
