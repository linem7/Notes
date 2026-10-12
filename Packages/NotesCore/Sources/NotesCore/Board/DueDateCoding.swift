import Foundation

/// `DueDate`（本地日历日 + 可选 "HH:mm"）和日期选择器用的 `Date` 互转。
extension DueDate {
    /// 取 `date` 在 `calendar` 里的日历日；`includesTime` 为 true 时同时取时分。
    public init(date: Date, includesTime: Bool, calendar: Calendar) {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let day = String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
        let time = includesTime ? String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0) : nil
        self.init(day: day, time: time)
    }

    /// 日期加上时间（没有时间时是当天 00:00）。`day` 不是一个真实存在的日期时返回 nil。
    ///
    /// **`Calendar.date(from:)` 是宽松的，不能直接信**：`2026-02-30`、`2026-13-01` 这些越界日子它
    /// 不返回 nil，而是顺延/夹到另一个日子（`DueDateCodingTests` 里对这组输入有断言）。所以算出日期后
    /// 把年月日取回来和输入比对，对不上就返回 nil —— 模型给的 Due Date 会经这条路
    /// （`OrganizeResponseParser`），非法值必须被丢掉，不能被静默改成另一天。
    public func date(calendar: Calendar) -> Date? {
        // 分段必须正好三段、每段都能解析成整数。原来用 `compactMap` 会把解析不出的段直接丢掉，
        // `"a-2026-10-12"` 会被当成 `2026-10-12` 收下。
        let d = day.split(separator: "-", omittingEmptySubsequences: false)
        guard d.count == 3, let year = Int(d[0]), let month = Int(d[1]), let dayOfMonth = Int(d[2]) else { return nil }
        var components = DateComponents(year: year, month: month, day: dayOfMonth)
        if let time {
            // 时分**只做范围校验，不回读**：夏令时跳变那一小时（如 America/New_York 的 2026-03-08
            // 02:30）里 `day` 是真实存在的一天、`time` 在范围内，`date(from:)` 会把它挪到 03:30 ——
            // 回读时分就会把这种输入判成非法（编辑器会退回今天）。而 `25:00` / `12:60` 用范围就拦得住。
            let t = time.split(separator: ":", omittingEmptySubsequences: false)
            guard t.count == 2, let hour = Int(t[0]), let minute = Int(t[1]),
                  (0...23).contains(hour), (0...59).contains(minute) else { return nil }
            components.hour = hour
            components.minute = minute
        }
        guard let date = calendar.date(from: components) else { return nil }
        let back = calendar.dateComponents([.year, .month, .day], from: date)
        guard back.year == year, back.month == month, back.day == dayOfMonth else { return nil }
        return date
    }
}
