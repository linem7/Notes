import Foundation
import NotesCore
import Observation
import os

/// Board 的视图模型：订阅 `NoteStoring.observe()`，按 `BoardSections` 分组，持有交互状态（`BoardState`）。
@MainActor
@Observable
final class BoardModel {
    private(set) var sections: [BoardSectionContent] = []
    private(set) var badgeCount = 0
    private(set) var state = BoardState()
    private(set) var now: Date
    private(set) var hasLoaded = false

    var calendar: Calendar
    let store: any NoteStoring
    let files: MaterialFiles

    @ObservationIgnored private var notes: [NoteWithMaterials] = []
    @ObservationIgnored private var observeTask: Task<Void, Never>?
    @ObservationIgnored private let highlightDuration: Duration
    @ObservationIgnored private let logger = Logger(subsystem: "com.linem7.Notes", category: "Board")

    init(
        store: any NoteStoring, files: MaterialFiles,
        calendar: Calendar = .current, now: Date = Date(), highlightDuration: Duration = .seconds(3)
    ) {
        self.store = store
        self.files = files
        self.calendar = calendar
        self.now = now
        self.highlightDuration = highlightDuration
    }

    func start() {
        guard observeTask == nil else { return }
        let stream = store.observe()
        observeTask = Task { [weak self] in
            for await items in stream {
                guard let self else { return }
                self.apply(items)
            }
        }
    }

    func stop() {
        observeTask?.cancel()
        observeTask = nil
    }

    /// 跨过午夜或系统唤醒后调用：重新判断「今天」并重新分组。
    func refreshToday(_ date: Date = Date()) {
        now = date
        regroup()
    }

    private func apply(_ items: [NoteWithMaterials]) {
        notes = items
        hasLoaded = true
        regroup()
        let started = state.reconcile(existing: Set(items.map(\.id)))
        if !started.isEmpty {
            Task { [weak self, highlightDuration] in
                try? await Task.sleep(for: highlightDuration)
                self?.state.expireHighlight(started)
            }
        }
    }

    private func regroup() {
        sections = BoardSections.sections(for: notes, today: now, calendar: calendar)
        badgeCount = BoardSections.badgeCount(for: notes, today: now, calendar: calendar)
    }

    // MARK: 交互状态

    func toggleExpanded(_ id: UUID) { state.toggleExpanded(id) }
    func beginEditing(_ id: UUID) { state.beginEditing(id) }
    func endEditing() { state.endEditing() }
    func setDoneExpanded(_ expanded: Bool) { state.isDoneExpanded = expanded }

    /// 新 Note 保存后调用（#9 通过 `BoardController.highlight(noteIDs:)`）。
    func highlight(noteIDs: [UUID]) {
        state.requestHighlight(noteIDs)
        // 它们可能已经在列表里（observe 先到）
        apply(notes)
    }

    // MARK: 写入（失败只记日志；observe 会重发真实状态，界面随之回滚）

    /// 保存编辑：只改 title、due、detail（完成状态只能走 `setDone`），基于 store 最近一次发来的 Note。
    func save(id: UUID, title: String, due: DueDate?, detail: String) {
        guard var note = notes.first(where: { $0.id == id })?.note else { return }
        note.title = title
        note.due = due
        note.detail = detail
        let updated = note
        run("update") { try await $0.update(updated) }
        state.endEditing()
    }

    func setDone(_ id: UUID, done: Bool) {
        let at: Date? = done ? Date() : nil
        run("setDone") { try await $0.setDone(id: id, at: at) }
    }

    func delete(_ id: UUID) {
        run("delete") { try await $0.delete(id: id) }
    }

    /// ⌫：删除选中的行（编辑中不删）。
    func deleteSelected() {
        guard let id = state.deletableID else { return }
        delete(id)
    }

    func addFiles(_ urls: [URL], to noteID: UUID) {
        for url in urls where url.isFileURL {
            run("addMaterial") { _ = try await $0.addMaterial(noteID: noteID, from: url, displayName: nil) }
        }
    }

    func deleteMaterial(_ id: UUID) {
        run("deleteMaterial") { try await $0.deleteMaterial(id: id) }
    }

    private func run(_ name: String, _ work: @escaping @Sendable (any NoteStoring) async throws -> Void) {
        let store = store
        let logger = logger
        Task {
            do {
                try await work(store)
            } catch {
                logger.error("\(name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
