import Foundation

/// Due Date 在 Board 上的显示意图。NotesCore 不放界面字符串，本地化文本由 App 层拼。
public struct DueDateDisplay: Equatable, Sendable {
    public enum Day: Equatable, Sendable {
        case yesterday
        case today
        case tomorrow
        /// `Calendar` 的 weekday：1 = 周日 … 7 = 周六。只用于未来 2–6 天内。
        case weekday(Int)
        /// 其余日期。`year` 与今年相同时为 nil。
        case date(year: Int?, month: Int, day: Int)
    }

    public enum Phase: Equatable, Sendable { case overdue, today, upcoming }

    public var day: Day
    public var time: String?
    public var phase: Phase

    public init(day: Day, time: String?, phase: Phase) {
        self.day = day
        self.time = time
        self.phase = phase
    }
}

public enum DueDateText {
    /// `due.day` 不是合法的 "yyyy-MM-dd" 时返回 nil。
    public static func display(for due: DueDate, today: Date, calendar: Calendar) -> DueDateDisplay? {
        // 和 BoardSections 用同一个判断：非法日期的 Note 在 No Date 里，不显示日期
        guard DueDate.isValidDay(due.day) else { return nil }
        let parts = due.day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        let components = DateComponents(year: parts[0], month: parts[1], day: parts[2])
        guard let dueStart = calendar.date(from: components),
              let diff = calendar.dateComponents(
                [.day], from: calendar.startOfDay(for: today), to: dueStart
              ).day
        else { return nil }

        let phase: DueDateDisplay.Phase = diff < 0 ? .overdue : (diff == 0 ? .today : .upcoming)
        let day: DueDateDisplay.Day
        switch diff {
        case -1: day = .yesterday
        case 0: day = .today
        case 1: day = .tomorrow
        case 2...6: day = .weekday(calendar.component(.weekday, from: dueStart))
        default:
            let thisYear = calendar.component(.year, from: today)
            day = .date(year: parts[0] == thisYear ? nil : parts[0], month: parts[1], day: parts[2])
        }
        return DueDateDisplay(day: day, time: due.time, phase: phase)
    }
}
