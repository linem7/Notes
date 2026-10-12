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
    /// 写入失败时短暂显示的红色提示条（"Couldn't save"）。
    private(set) var showsSaveError = false

    var calendar: Calendar
    let store: any NoteStoring
    let files: MaterialFiles

    @ObservationIgnored private var notes: [NoteWithMaterials] = []
    @ObservationIgnored private var observeTask: Task<Void, Never>?
    @ObservationIgnored private var errorTask: Task<Void, Never>?
    /// 所有写入排成一队按顺序执行（比如编辑中勾选自己：先 update 再 setDone），每个写入 10 秒超时。
    @ObservationIgnored private let writeQueue = SerialWriteQueue(timeout: .seconds(10))
    /// 正在编辑的 NoteEditor 登记的「保存」动作；失焦时调用。
    @ObservationIgnored private var editingCommit: (() -> Void)?
    @ObservationIgnored private let errorDuration: Duration
    @ObservationIgnored private let highlightDuration: Duration
    @ObservationIgnored private let logger = Logger(subsystem: "com.linem7.Notes", category: "Board")

    init(
        store: any NoteStoring, files: MaterialFiles,
        calendar: Calendar = .autoupdatingCurrent, now: Date = Date(), highlightDuration: Duration = .seconds(3),
        errorDuration: Duration = .seconds(4)
    ) {
        self.store = store
        self.files = files
        self.calendar = calendar
        self.now = now
        self.highlightDuration = highlightDuration
        self.errorDuration = errorDuration
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
        let started = reconcileState()
        if !started.isEmpty {
            Task { [weak self, highlightDuration] in
                try? await Task.sleep(for: highlightDuration)
                self?.state.expireHighlight(started)
            }
        }
    }

    /// 把交互状态和当前列表对齐：删除的行、折叠着的 Done 区里的行不能保持展开、编辑或选中。
    @discardableResult
    private func reconcileState() -> Set<UUID> {
        let existing = Set(notes.map(\.id))
        let hidden = state.isDoneExpanded ? [] : Set(notes.filter { $0.note.doneAt != nil }.map(\.id))
        return state.reconcile(existing: existing, visible: existing.subtracting(hidden))
    }

    private func regroup() {
        sections = BoardSections.sections(for: notes, today: now, calendar: calendar)
        badgeCount = BoardSections.badgeCount(for: notes, today: now, calendar: calendar)
    }

    // MARK: 交互状态

    /// 点一行：没在编辑时直接展开/收起；编辑中先让编辑器提交，保存成功后再展开这一行。
    func toggleExpanded(_ id: UUID) {
        if !state.requestToggle(id) { commitEditing() }
    }

    /// 编辑中失焦（点 Board 别处、切到别的 app、点顶栏按钮等）时保存；没在编辑时什么也不做。
    func commitEditing() { editingCommit?() }

    /// NoteEditor 出现时登记保存动作，消失时传 nil。消失时若仍在编辑，先提交一次；之后拿不到内容，编辑随之结束。
    func registerEditingCommit(_ commit: (() -> Void)?) {
        // 编辑器在编辑中被回收（滚出可视区、分组变化重建）：注销之前先提交，免得修改悄悄丢掉。
        // 已经保存或 Esc 过的（editingID 为 nil）不重复保存。
        if commit == nil, state.editingID != nil { editingCommit?() }
        editingCommit = commit
        state.setEditorAvailable(commit != nil)
    }

    func beginEditing(_ id: UUID) { state.beginEditing(id) }
    /// Esc：放弃修改，任何时候都能退出编辑。
    func cancelEditing() { state.cancelEditing() }
    /// 失焦时没有改动：结束编辑（并展开刚才点的行）。
    func finishEditingWithoutChanges() { state.finishEditingWithoutChanges() }

    func setDoneExpanded(_ expanded: Bool) {
        state.isDoneExpanded = expanded
        reconcileState()
    }

    /// 新 Note 保存后调用（#9 通过 `BoardController.highlight(noteIDs:)`）。
    func highlight(noteIDs: [UUID]) {
        state.requestHighlight(noteIDs)
        // 它们可能已经在列表里（observe 先到）
        apply(notes)
    }

    // MARK: 写入（按顺序执行；失败时记日志并显示 "Couldn't save" 条，列表仍以 store 为准）

    /// 保存编辑：只改 title、due、detail（完成状态只能走 `setDone`），基于 store 最近一次发来的 Note。
    /// 等 `update` 成功后才结束编辑；失败时留在编辑状态，用户输入还在，Esc 可以放弃。
    func save(id: UUID, title: String, due: DueDate?, detail: String) {
        guard var note = notes.first(where: { $0.id == id })?.note else { return }
        note.title = title
        note.due = due
        note.detail = detail
        let updated = note
        enqueue(
            "update", { try await $0.update(updated) },
            onSuccess: { [weak self] in self?.state.saveFinished(id: id, succeeded: true) },
            onFailure: { [weak self] in self?.state.saveFinished(id: id, succeeded: false) }
        )
    }

    func setDone(_ id: UUID, done: Bool) {
        commitEditing()
        let at: Date? = done ? Date() : nil
        enqueue("setDone") { try await $0.setDone(id: id, at: at) }
    }

    func delete(_ id: UUID) {
        commitEditing()
        enqueue("delete") { try await $0.delete(id: id) }
    }

    /// ⌫：删除选中的行（编辑中不删）。
    func deleteSelected() {
        guard let id = state.deletableID else { return }
        delete(id)
    }

    /// 拖入的文件按顺序加入；有失败时错误条只显示一次。
    func addFiles(_ urls: [URL], to noteID: UUID) {
        let fileURLs = urls.filter(\.isFileURL)
        guard !fileURLs.isEmpty else { return }
        let logger = logger
        enqueue("addMaterial") { store in
            var failed = false
            for url in fileURLs {
                do {
                    _ = try await store.addMaterial(noteID: noteID, from: url, displayName: nil)
                } catch {
                    logger.error("addMaterial failed: \(error.localizedDescription, privacy: .public)")
                    failed = true
                }
            }
            if failed { throw PartialFailure() }
        }
    }

    func deleteMaterial(_ id: UUID) {
        enqueue("deleteMaterial") { try await $0.deleteMaterial(id: id) }
    }

    private struct PartialFailure: Error {}

    private func enqueue(
        _ name: String,
        _ work: @escaping @Sendable (any NoteStoring) async throws -> Void,
        onSuccess: @escaping @MainActor () -> Void = {},
        onFailure: @escaping @MainActor () -> Void = {}
    ) {
        let store = store
        writeQueue.enqueue({ try await work(store) }) { [weak self] error in
            await self?.writeFinished(name, error: error, onSuccess: onSuccess, onFailure: onFailure)
        }
    }

    /// 写入完成（成功、失败或超时）。超时按失败处理：显示错误条，队列继续往下走。
    private func writeFinished(
        _ name: String, error: Error?,
        onSuccess: @MainActor () -> Void, onFailure: @MainActor () -> Void
    ) {
        guard let error else {
            onSuccess()
            return
        }
        logger.error("\(name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        flashSaveError()
        onFailure()
    }

    private func flashSaveError() {
        showsSaveError = true
        errorTask?.cancel()
        errorTask = Task { [weak self, errorDuration] in
            try? await Task.sleep(for: errorDuration)
            guard !Task.isCancelled else { return }
            self?.showsSaveError = false
        }
    }
}
