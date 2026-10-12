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

    /// 日期加上时间（没有时间时是当天 00:00）。`day` 不合法时返回 nil。
    public func date(calendar: Calendar) -> Date? {
        let d = day.split(separator: "-").compactMap { Int($0) }
        guard d.count == 3 else { return nil }
        var components = DateComponents(year: d[0], month: d[1], day: d[2])
        if let time {
            let t = time.split(separator: ":").compactMap { Int($0) }
            guard t.count == 2 else { return nil }
            components.hour = t[0]
            components.minute = t[1]
        }
        return calendar.date(from: components)
    }
}
