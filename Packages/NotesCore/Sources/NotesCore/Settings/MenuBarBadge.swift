import Foundation
import Observation

/// 菜单栏图标旁的数字：今天到期 + 已逾期的未完成 Note 数量（SPEC §1）。订阅 `NoteStoring.observe()`。
@MainActor
@Observable
public final class MenuBarBadge {
    public private(set) var count = 0
    /// 收到过至少一次 store 的快照。
    public private(set) var isLoaded = false

    @ObservationIgnored private var notes: [NoteWithMaterials] = []
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let calendar: Calendar
    @ObservationIgnored private let now: @Sendable () -> Date

    public init(calendar: Calendar = .autoupdatingCurrent, now: @escaping @Sendable () -> Date = { Date() }) {
        self.calendar = calendar
        self.now = now
    }

    public func start(store: any NoteStoring) {
        task?.cancel()
        let stream = store.observe()
        task = Task { [weak self] in
            for await notes in stream {
                guard let self, !Task.isCancelled else { return }
                self.notes = notes
                self.isLoaded = true
                self.refresh()
            }
        }
    }

    /// 跨过午夜、时区改变或系统唤醒后重新判断「今天」。
    public func refresh() {
        count = BoardSections.badgeCount(for: notes, today: now(), calendar: calendar)
    }

    /// 为 0 时不显示数字。
    public var label: String? { count > 0 ? String(count) : nil }

    deinit { task?.cancel() }
}
