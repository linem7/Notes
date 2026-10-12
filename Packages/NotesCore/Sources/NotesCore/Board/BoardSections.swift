import Foundation

/// Board 的分组，声明顺序就是从上到下的顺序（SPEC §2.2）。
public enum BoardSection: CaseIterable, Hashable, Sendable {
    case overdue, today, upcoming, noDate, done
}

public struct BoardSectionContent: Identifiable, Hashable, Sendable {
    public var section: BoardSection
    public var notes: [NoteWithMaterials]
    public var id: BoardSection { section }
}

/// 分组和排序，纯函数（ARCHITECTURE §7）。「今天」由 `today` 和 `calendar`（含时区）决定，
/// Due Date 的 day 是本地日历日字符串，按字符串比较（"yyyy-MM-dd" 的字典序就是日期序）。
public enum BoardSections {
    public static func sections(for notes: [NoteWithMaterials], today: Date, calendar: Calendar) -> [BoardSectionContent] {
        let todayDay = dayString(today, calendar: calendar)
        var groups: [BoardSection: [NoteWithMaterials]] = [:]
        for item in notes {
            groups[section(of: item.note, todayDay: todayDay), default: []].append(item)
        }
        return BoardSection.allCases.compactMap { section in
            guard let items = groups[section], !items.isEmpty else { return nil }
            return BoardSectionContent(section: section, notes: items.sorted(by: order(of: section)))
        }
    }

    /// 菜单栏数字：今天到期 + 已逾期的未完成 Note。
    public static func badgeCount(for notes: [NoteWithMaterials], today: Date, calendar: Calendar) -> Int {
        let todayDay = dayString(today, calendar: calendar)
        return notes.filter {
            switch section(of: $0.note, todayDay: todayDay) {
            case .overdue, .today: true
            default: false
            }
        }.count
    }

    static func dayString(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func isValidDay(_ day: String) -> Bool {
        let parts = day.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.map(\.count) == [4, 2, 2],
              let year = Int(parts[0]), let month = Int(parts[1]), let d = Int(parts[2]),
              parts.allSatisfy({ $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }) else { return false }
        return DateComponents(calendar: Calendar(identifier: .gregorian), year: year, month: month, day: d).isValidDate
    }

    private static func section(of note: Note, todayDay: String) -> BoardSection {
        if note.doneAt != nil { return .done }
        // 不是真实日历日的 day（空串、"2026-13-40"）当作没有 Due Date，免得字符串比较把它排进 Overdue
        guard let due = note.due, isValidDay(due.day) else { return .noDate }
        if due.day < todayDay { return .overdue }
        if due.day == todayDay { return .today }
        return .upcoming
    }

    private static func order(of section: BoardSection) -> (NoteWithMaterials, NoteWithMaterials) -> Bool {
        switch section {
        case .overdue, .today, .upcoming:
            // 日期、时间升序（没有时间的排在同一天有时间的后面），再按创建时间升序
            return { lhs, rhs in
                key(lhs.note) < key(rhs.note)
            }
        case .noDate:
            return { lhs, rhs in
                if lhs.note.createdAt != rhs.note.createdAt { return lhs.note.createdAt > rhs.note.createdAt }
                return lhs.note.id.uuidString < rhs.note.id.uuidString
            }
        case .done:
            return { lhs, rhs in
                let l = lhs.note.doneAt ?? .distantPast, r = rhs.note.doneAt ?? .distantPast
                if l != r { return l > r }
                return lhs.note.id.uuidString < rhs.note.id.uuidString
            }
        }
    }

    private static func key(_ note: Note) -> DueKey {
        DueKey(day: note.due?.day ?? "", time: note.due?.time ?? "99:99", createdAt: note.createdAt, id: note.id.uuidString)
    }

    private struct DueKey: Comparable {
        var day: String
        var time: String
        var createdAt: Date
        var id: String

        static func < (lhs: DueKey, rhs: DueKey) -> Bool {
            (lhs.day, lhs.time, lhs.createdAt, lhs.id) < (rhs.day, rhs.time, rhs.createdAt, rhs.id)
        }
    }
}
