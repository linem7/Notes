import NotesCore
import SwiftUI

/// 把 `DueDateDisplay`（NotesCore 的结构化结果）拼成界面文字。
enum DueDateFormat {
    static func string(_ display: DueDateDisplay, calendar: Calendar) -> String {
        let day: String
        switch display.day {
        case .yesterday: day = String(localized: "Yesterday")
        case .today: day = String(localized: "Today")
        case .tomorrow: day = String(localized: "Tomorrow")
        case .weekday(let weekday): day = calendar.weekdaySymbols[(weekday - 1) % 7]
        case .date(let year, let month, let dayOfMonth):
            var components = DateComponents(year: year ?? calendar.component(.year, from: Date()), month: month, day: dayOfMonth)
            components.calendar = calendar
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.locale = calendar.locale ?? .current
            formatter.timeZone = calendar.timeZone
            formatter.setLocalizedDateFormatFromTemplate(year == nil ? "MMMd" : "yMMMd")
            day = components.date.map(formatter.string(from:)) ?? "\(month)/\(dayOfMonth)"
        }
        guard let time = display.time else { return day }
        return "\(day) \(time)"
    }
}

struct DueDateLabel: View {
    let due: DueDate
    let isDone: Bool
    let today: Date
    let calendar: Calendar

    var body: some View {
        if let display = DueDateText.display(for: due, today: today, calendar: calendar) {
            Text(DueDateFormat.string(display, calendar: calendar))
                .font(.system(size: 11, weight: display.phase == .upcoming ? .regular : .medium))
                .foregroundStyle(isDone ? AnyShapeStyle(HierarchicalShapeStyle.secondary) : color(display.phase))
                .lineLimit(1)
        }
    }

    private func color(_ phase: DueDateDisplay.Phase) -> AnyShapeStyle {
        switch phase {
        case .overdue: AnyShapeStyle(Color.red)
        case .today: AnyShapeStyle(Color.accentColor)
        case .upcoming: AnyShapeStyle(HierarchicalShapeStyle.secondary)
        }
    }
}
