import Foundation
import Testing
@testable import NotesCore

@MainActor
struct MenuBarBadgeTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }

    private func noon(_ day: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: 12))!
    }

    private func note(_ title: String, due: String?, done: Bool = false) -> Note {
        Note(title: title, due: due.map { DueDate(day: $0) }, doneAt: done ? noon(1) : nil)
    }

    private func waitForCount(_ badge: MenuBarBadge, _ expected: Int) async {
        for _ in 0..<300 where !badge.isLoaded || badge.count != expected {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func countsTodayAndOverdueUndoneNotesOnly() async throws {
        let store = InMemoryNoteStore()
        try await store.insert(notes: [
            note("late", due: "2026-10-11"),
            note("today", due: "2026-10-12"),
            note("soon", due: "2026-10-13"),
            note("someday", due: nil),
            note("finished", due: "2026-10-01", done: true),
        ], materials: [])
        let today = noon(12)
        let badge = MenuBarBadge(calendar: calendar, now: { today })
        badge.start(store: store)
        await waitForCount(badge, 2)
        #expect(badge.count == 2)
        #expect(badge.label == "2")
    }

    @Test func zeroHidesTheNumber() {
        let badge = MenuBarBadge(calendar: calendar)
        #expect(badge.count == 0)
        #expect(badge.label == nil)
    }

    @Test func updatesWhenNotesChangeAndWhenTheDayChanges() async throws {
        let store = InMemoryNoteStore()
        let tomorrowNote = note("soon", due: "2026-10-13")
        try await store.insert(notes: [tomorrowNote], materials: [])
        let clock = MutableClock(noon(12))
        let badge = MenuBarBadge(calendar: calendar, now: { clock.value })
        badge.start(store: store)
        await waitForCount(badge, 0)
        #expect(badge.count == 0)

        // 跨过午夜：明天到期的变成今天到期
        clock.value = noon(13)
        badge.refresh()
        #expect(badge.count == 1)

        try await store.setDone(id: tomorrowNote.id, at: noon(13))
        await waitForCount(badge, 0)
        #expect(badge.count == 0)
    }
}

private final class MutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Date
    init(_ value: Date) { _value = value }
    var value: Date {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}
