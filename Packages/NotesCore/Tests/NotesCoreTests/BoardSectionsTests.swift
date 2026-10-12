import Foundation
import Testing
@testable import NotesCore

struct BoardSectionsTests {
    private func calendar(_ zone: String = "Asia/Shanghai") -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, _ min: Int = 0, calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    private func item(
        _ title: String, due: DueDate? = nil, done: Date? = nil, created: TimeInterval = 0
    ) -> NoteWithMaterials {
        NoteWithMaterials(note: Note(
            title: title, due: due, doneAt: done,
            createdAt: Date(timeIntervalSinceReferenceDate: created)
        ))
    }

    private func titles(_ sections: [BoardSectionContent], _ section: BoardSection) -> [String] {
        sections.first { $0.section == section }?.notes.map(\.note.title) ?? []
    }

    @Test func notesLandInTheirSectionsAndEmptySectionsAreOmitted() {
        let cal = calendar()
        let today = date(2026, 10, 12, calendar: cal)
        let sections = BoardSections.sections(for: [
            item("late", due: DueDate(day: "2026-10-11")),
            item("now", due: DueDate(day: "2026-10-12")),
            item("soon", due: DueDate(day: "2026-10-13")),
            item("someday"),
            item("finished", due: DueDate(day: "2026-10-01"), done: today),
        ], today: today, calendar: cal)
        #expect(sections.map(\.section) == [.overdue, .today, .upcoming, .noDate, .done])

        let partial = BoardSections.sections(for: [item("now", due: DueDate(day: "2026-10-12"))], today: today, calendar: cal)
        #expect(partial.map(\.section) == [.today])
        #expect(BoardSections.sections(for: [], today: today, calendar: cal).isEmpty)
    }

    @Test func datedNotesSortByDayThenTimeWithUntimedAfterTimedThenCreation() {
        let cal = calendar()
        let today = date(2026, 10, 12, calendar: cal)
        let sections = BoardSections.sections(for: [
            item("untimed", due: DueDate(day: "2026-10-12"), created: 1),
            item("evening", due: DueDate(day: "2026-10-12", time: "18:00"), created: 2),
            item("morning", due: DueDate(day: "2026-10-12", time: "09:00"), created: 3),
            item("morning-later-created", due: DueDate(day: "2026-10-12", time: "09:00"), created: 4),
            item("untimed-older", due: DueDate(day: "2026-10-12"), created: 0),
        ], today: today, calendar: cal)
        #expect(titles(sections, .today) == ["morning", "morning-later-created", "evening", "untimed-older", "untimed"])
    }

    @Test func upcomingSortsByDay() {
        let cal = calendar()
        let today = date(2026, 10, 12, calendar: cal)
        let sections = BoardSections.sections(for: [
            item("c", due: DueDate(day: "2026-11-01")),
            item("a", due: DueDate(day: "2026-10-13")),
            item("b", due: DueDate(day: "2026-10-20")),
        ], today: today, calendar: cal)
        #expect(titles(sections, .upcoming) == ["a", "b", "c"])
    }

    @Test func noDateIsNewestFirstAndDoneIsMostRecentlyDoneFirst() {
        let cal = calendar()
        let today = date(2026, 10, 12, calendar: cal)
        let sections = BoardSections.sections(for: [
            item("old", created: 1), item("new", created: 9), item("mid", created: 5),
            item("done-early", done: Date(timeIntervalSinceReferenceDate: 100)),
            item("done-late", done: Date(timeIntervalSinceReferenceDate: 200)),
        ], today: today, calendar: cal)
        #expect(titles(sections, .noDate) == ["new", "mid", "old"])
        #expect(titles(sections, .done) == ["done-late", "done-early"])
    }

    @Test func crossingMidnightRegroupsTodayIntoOverdue() {
        let cal = calendar()
        let notes = [item("task", due: DueDate(day: "2026-10-12"))]
        let before = BoardSections.sections(for: notes, today: date(2026, 10, 12, 23, 59, calendar: cal), calendar: cal)
        let after = BoardSections.sections(for: notes, today: date(2026, 10, 13, 0, 1, calendar: cal), calendar: cal)
        #expect(before.map(\.section) == [.today])
        #expect(after.map(\.section) == [.overdue])
    }

    @Test func todayFollowsTheCalendarTimeZone() {
        // 同一时刻：上海已经是 10-13，洛杉矶还是 10-12
        let shanghai = calendar("Asia/Shanghai")
        let instant = date(2026, 10, 13, 8, 0, calendar: shanghai)
        let notes = [item("task", due: DueDate(day: "2026-10-12"))]
        #expect(BoardSections.sections(for: notes, today: instant, calendar: shanghai).map(\.section) == [.overdue])
        #expect(BoardSections.sections(for: notes, today: instant, calendar: calendar("America/Los_Angeles")).map(\.section) == [.today])
    }

    @Test func aTimeEarlierTodayStaysInToday() {
        let cal = calendar()
        let today = date(2026, 10, 12, 20, 0, calendar: cal)
        let sections = BoardSections.sections(for: [item("t", due: DueDate(day: "2026-10-12", time: "08:00"))], today: today, calendar: cal)
        #expect(sections.map(\.section) == [.today])
    }

    @Test func badgeCountsOverdueAndTodayNotDone() {
        let cal = calendar()
        let today = date(2026, 10, 12, calendar: cal)
        let count = BoardSections.badgeCount(for: [
            item("late", due: DueDate(day: "2026-10-01")),
            item("now", due: DueDate(day: "2026-10-12")),
            item("done-late", due: DueDate(day: "2026-10-01"), done: today),
            item("soon", due: DueDate(day: "2026-10-13")),
            item("someday"),
        ], today: today, calendar: cal)
        #expect(count == 2)
    }
}
