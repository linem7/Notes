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

    /// `Calendar.date(from:)` 对越界分量不会给 nil，而是顺延/夹到别的日子（#37）。每条非法输入都配一条
    /// 同样形状的正对照：只有「非法给 nil」和「合法给日期」同时成立，才说明拦住的是越界而不是整个函数。
    /// 旧实现下这组用例是红的（`2026-02-30` 会拿到一个非 nil 的 3 月的日期）。
    @Test func outOfRangeComponentsReturnNilInsteadOfRollingOver() {
        #expect(DueDate(day: "2026-02-30").date(calendar: calendar) == nil)                     // 2026 年 2 月只有 28 天
        #expect(DueDate(day: "2026-13-01").date(calendar: calendar) == nil)                     // 没有 13 月
        #expect(DueDate(day: "2026-04-31").date(calendar: calendar) == nil)                     // 4 月只有 30 天
        #expect(DueDate(day: "2026-00-10").date(calendar: calendar) == nil)
        #expect(DueDate(day: "2026-10-00").date(calendar: calendar) == nil)
        #expect(DueDate(day: "2026-10-12", time: "25:00").date(calendar: calendar) == nil)
        #expect(DueDate(day: "2026-10-12", time: "12:60").date(calendar: calendar) == nil)

        #expect(DueDate(day: "2026-02-28").date(calendar: calendar) != nil)
        #expect(DueDate(day: "2026-12-01").date(calendar: calendar) != nil)
        #expect(DueDate(day: "2026-04-30").date(calendar: calendar) != nil)
        #expect(DueDate(day: "2026-10-12", time: "23:59").date(calendar: calendar) != nil)
        #expect(DueDate(day: "2026-10-12", time: "00:00").date(calendar: calendar) != nil)
    }

    /// 分段数不对、解析不出整数的段，原样拒绝 —— `compactMap` 会把它们悄悄丢掉（#37）。
    @Test func malformedShapesAreRejectedInsteadOfDroppingSegments() {
        #expect(DueDate(day: "2026-10-12-").date(calendar: calendar) == nil)
        #expect(DueDate(day: "2026--10-12").date(calendar: calendar) == nil)
        #expect(DueDate(day: "a-2026-10-12").date(calendar: calendar) == nil)
        #expect(DueDate(day: "x-y-z").date(calendar: calendar) == nil)
        #expect(DueDate(day: "2026-10-12", time: "12:00:00").date(calendar: calendar) == nil)
        #expect(DueDate(day: "2026-10-12", time: "12:").date(calendar: calendar) == nil)

        #expect(DueDate(day: "2026-10-12").date(calendar: calendar) != nil)
        #expect(DueDate(day: "2026-10-12", time: "12:00").date(calendar: calendar) != nil)
    }

    /// 夏令时跳变那一小时（`America/New_York` 2026-03-08 02:30 不存在，`date(from:)` 会挪到 03:30）里，
    /// `day` 是真实存在的那一天、`time` 是范围内的合法值 —— 这类输入不该被判成非法（判成 nil 会让编辑器
    /// 退回今天）。所以回读校验只比年月日、不比时分。
    /// 反面对照：同样越界的 `25:00` / `02:60` 由范围校验拦住。
    /// （断言对 tzdata 是否真在 03-08 跳变不敏感：真有跳变→返回 03:30 非 nil，没跳变→返回 02:30 非 nil，两种都过。）
    @Test func timesInsideADSTGapAreAcceptedWhileOutOfRangeTimesAreNot() {
        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = TimeZone(identifier: "America/New_York")!
        #expect(DueDate(day: "2026-03-08", time: "02:30").date(calendar: newYork) != nil)
        #expect(DueDate(day: "2026-03-08", time: "12:30").date(calendar: newYork) != nil)
        #expect(DueDate(day: "2026-03-08", time: "25:00").date(calendar: newYork) == nil)
        #expect(DueDate(day: "2026-03-08", time: "02:60").date(calendar: newYork) == nil)
        #expect(DueDate(day: "2026-03-08", time: "02:30").date(calendar: calendar) != nil)   // 本机时区没有夏令时
    }
}
