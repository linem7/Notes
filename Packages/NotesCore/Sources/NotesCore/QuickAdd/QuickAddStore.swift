import Foundation
import Observation

/// Quick Add 的状态：输入、Material 条、Organize、Draft、保存（ARCHITECTURE §8，SPEC §3）。
/// 面板隐藏不碰这里的任何状态，所以隐藏后再唤起，Draft 和进行中的 Organize 保持原状。
@MainActor
@Observable
public final class QuickAddStore {
    public enum Failure: Equatable, Sendable {
        /// 没有 Connection（或 Default Model、key）：Draft 区提示先添加，并给打开设置的按钮。
        case noConnection
        case chat(ChatError)
    }

    public enum Phase: Equatable, Sendable {
        case idle
        /// 已收到的字数，作为进度。
        case organizing(received: Int)
        case drafts
        case failed(Failure)
    }

    /// 一个在 Material 条里的块。
    public struct Item: Identifiable, Equatable, Sendable {
        public var staged: StagedMaterial
        public var prepared: PreparedText
        /// 从输入框里自动识别出来的链接（输入里没有这个链接了就一起去掉）。
        public var isAutoLink: Bool
        public var id: UUID { staged.id }
        public var state: ReadableTextState { prepared.state }
    }

    /// 复制进 staging 失败的文件：显示成带警告的小块，悬停说明，可以移除。
    public struct StageFailure: Identifiable, Equatable, Sendable {
        public var id = UUID()
        public var name: String
    }

    // MARK: 状态

    public var inputText: String = "" {
        didSet { if inputText != oldValue { scheduleLinkDetection() } }
    }
    public private(set) var items: [Item] = []
    public private(set) var stageFailures: [StageFailure] = []
    public var drafts: [Draft] = []
    public private(set) var phase: Phase = .idle
    public private(set) var isSaving = false
    /// 上一次保存失败了；下一次保存开始或清空时复位。
    public private(set) var saveFailed = false

    /// 当前 staging 会话的 id，还没有加入过 Material 时为 nil。保存或清空后回到 nil。
    /// 给每 24 小时的清理读取（`NotesMaintenance` 的 `keepingStaging`）。
    public var currentStagingSessionID: UUID? { intake?.sessionID }

    /// 有输入、Material、Draft 或正在 Organize；用来判断「空白」。
    public var hasContent: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !items.isEmpty || !drafts.isEmpty
            || !stageFailures.isEmpty
    }

    /// 隐藏面板后需要保持原状（SPEC §3.1）。
    public var hasUnsavedWork: Bool {
        if case .organizing = phase { return true }
        return hasContent
    }

    public var isOrganizing: Bool {
        if case .organizing = phase { return true }
        return false
    }

    /// ⏎ 可用：不在 Organize，也不在保存，并且有文字或 Material。
    public var canOrganize: Bool {
        !isOrganizing && !isSaving && hasInput
    }

    public var canSave: Bool {
        guard !isOrganizing, !isSaving else { return false }
        if drafts.isEmpty { return hasInput }
        return drafts.contains(where: \.isSelected)
    }

    private var hasInput: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !items.isEmpty
    }

    // MARK: 依赖

    private let organizer: any DraftOrganizing
    private let saver: any QuickAddSaving
    private let makeIntake: @Sendable () throws -> any QuickAddIntaking
    private weak var highlighter: (any NoteHighlighting)?
    private let pendingTimeout: Duration
    private let linkDetectionDelay: Duration
    private let now: @Sendable () -> Date

    private var intake: (any QuickAddIntaking)?
    private var prepareTasks: [UUID: Task<Void, Never>] = [:]
    private var organizeTask: Task<Void, Never>?
    private var organizeGeneration = 0
    private var linkTask: Task<Void, Never>?
    /// 用户 × 掉的链接，不再自动识别。
    private var dismissedLinks: Set<URL> = []
    /// Organize 时发给模型的 Material；Draft 的 `materialIndices` 指向它。
    private var organizedMaterials: [OrganizeMaterial] = []

    /// 保存成功之后调用（控制器用它隐藏面板）。
    public var onDidSave: (() -> Void)?

    public init(
        organizer: any DraftOrganizing,
        saver: any QuickAddSaving,
        makeIntake: @escaping @Sendable () throws -> any QuickAddIntaking,
        highlighter: (any NoteHighlighting)? = nil,
        pendingTimeout: Duration = .seconds(30),
        linkDetectionDelay: Duration = .milliseconds(800),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.organizer = organizer
        self.saver = saver
        self.makeIntake = makeIntake
        self.highlighter = highlighter
        self.pendingTimeout = pendingTimeout
        self.linkDetectionDelay = linkDetectionDelay
        self.now = now
    }

    public func setHighlighter(_ highlighter: (any NoteHighlighting)?) {
        self.highlighter = highlighter
    }

    // MARK: Material

    public func addFiles(_ urls: [URL]) {
        for url in urls {
            guard let intake = ensureIntake() else {
                stageFailures.append(StageFailure(name: url.lastPathComponent))
                continue
            }
            do {
                add(try intake.stage(fileAt: url), isAutoLink: false)
            } catch {
                stageFailures.append(StageFailure(name: url.lastPathComponent))
            }
        }
    }

    public func addImageData(_ data: Data) {
        guard let intake = ensureIntake() else {
            stageFailures.append(StageFailure(name: "Pasted Image"))
            return
        }
        do {
            add(try intake.stage(imageData: data), isAutoLink: false)
        } catch {
            stageFailures.append(StageFailure(name: "Pasted Image"))
        }
    }

    /// 移除一个 Material 块（×）。自动识别的链接移除后不再抓取，文字照旧。
    public func removeItem(id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let item = items.remove(at: index)
        prepareTasks.removeValue(forKey: id)?.cancel()
        if let url = item.staged.url { dismissedLinks.insert(url) }
    }

    public func removeStageFailure(id: UUID) {
        stageFailures.removeAll { $0.id == id }
    }

    /// Draft 上挂着的 Material（× 去掉的和已从 Material 条移除的不在其中）。
    public func materials(of draft: Draft) -> [StagedMaterial] {
        let present = Set(items.map(\.id))
        return draft.materialIndices.compactMap { index in
            guard organizedMaterials.indices.contains(index) else { return nil }
            let staged = organizedMaterials[index].staged
            return present.contains(staged.id) ? staged : nil
        }
    }

    /// 从一条 Draft 上去掉一个 Material（只是不挂，文件仍在 Material 条里）。
    public func detach(materialID: UUID, from draftID: UUID) {
        guard let position = drafts.firstIndex(where: { $0.id == draftID }) else { return }
        drafts[position].materialIndices.removeAll { index in
            organizedMaterials.indices.contains(index) && organizedMaterials[index].staged.id == materialID
        }
    }

    private func add(_ staged: StagedMaterial, isAutoLink: Bool) {
        guard let intake else { return }
        items.append(Item(staged: staged, prepared: PreparedText(state: .pending), isAutoLink: isAutoLink))
        let id = staged.id
        prepareTasks[id] = Task { [weak self] in
            let prepared = await intake.prepare(staged)
            guard !Task.isCancelled else { return }
            self?.finishPrepare(id: id, prepared)
        }
    }

    private func finishPrepare(id: UUID, _ prepared: PreparedText) {
        prepareTasks[id] = nil
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].prepared = prepared
        if let title = prepared.title, items[index].staged.kind == .webPage {
            items[index].staged.displayName = title
        }
    }

    private func ensureIntake() -> (any QuickAddIntaking)? {
        if let intake { return intake }
        intake = try? makeIntake()
        return intake
    }

    // MARK: 链接

    private func scheduleLinkDetection() {
        linkTask?.cancel()
        let delay = linkDetectionDelay
        linkTask = Task { [weak self] in
            // 等输入停一会儿再识别，免得一边打字一边抓半截链接
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.detectLinks()
        }
    }

    /// 立刻识别输入里的链接：新的加进 Material 条（最多前 5 个），已经不在文字里的自动块去掉。
    public func detectLinks() {
        linkTask?.cancel()
        let found = LinkDetector.links(in: inputText)
        let foundSet = Set(found)
        for item in items where item.isAutoLink {
            if let url = item.staged.url, !foundSet.contains(url) {
                items.removeAll { $0.id == item.id }
                prepareTasks.removeValue(forKey: item.id)?.cancel()
            }
        }
        // 用户 × 掉的链接文字没了，之后再输入同一个链接就当新的
        dismissedLinks = dismissedLinks.intersection(foundSet)
        let existing = Set(items.compactMap(\.staged.url))
        for url in found where !existing.contains(url) && !dismissedLinks.contains(url) {
            guard let intake = ensureIntake() else { return }
            add(intake.stage(url: url), isAutoLink: true)
        }
    }

    // MARK: Organize

    /// ⏎。已有 Draft 时新结果替换旧 Draft。
    public func organize() {
        guard canOrganize else { return }
        detectLinks()
        organizeTask?.cancel()
        organizeGeneration += 1
        let generation = organizeGeneration
        drafts = []
        phase = .organizing(received: 0)
        organizeTask = Task { [weak self] in
            await self?.runOrganize(generation: generation)
        }
    }

    /// ⌘. 或 Organize 中按 Esc：取消，面板不动。
    public func cancelOrganize() {
        guard isOrganizing else { return }
        organizeGeneration += 1
        organizeTask?.cancel()
        organizeTask = nil
        phase = .idle
    }

    private func runOrganize(generation: Int) async {
        await waitForPending()
        guard generation == organizeGeneration, !Task.isCancelled else { return }
        let materials = items.map { OrganizeMaterial(staged: $0.staged, prepared: $0.prepared) }
        organizedMaterials = materials
        let input = inputText
        do {
            let result = try await organizer.organize(input: input, materials: materials) { [weak self] count in
                Task { @MainActor in self?.updateProgress(count, generation: generation) }
            }
            guard generation == organizeGeneration, !Task.isCancelled else { return }
            drafts = result
            phase = .drafts
        } catch is CancellationError {
            return
        } catch {
            guard generation == organizeGeneration, !Task.isCancelled else { return }
            phase = .failed(Self.failure(for: error))
        }
    }

    private func updateProgress(_ count: Int, generation: Int) {
        guard generation == organizeGeneration, case .organizing = phase else { return }
        phase = .organizing(received: count)
    }

    private static func failure(for error: Error) -> Failure {
        if let setup = error as? OrganizeSetupError, setup == .noConnection { return .noConnection }
        if let chat = error as? ChatError { return .chat(chat) }
        return .chat(.providerError(error.localizedDescription))
    }

    /// 等所有还在准备 Readable Text 的 Material，最多 `pendingTimeout`。到点还没完成的真的取消（释放抓取名额），
    /// 标为 unavailable，当 readable="false"。
    private func waitForPending() async {
        let tasks = items.compactMap { prepareTasks[$0.id] }
        guard !tasks.isEmpty else { return }
        let timeout = pendingTimeout
        let finished = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for task in tasks { await task.value }
                return true
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return false
            }
            let first = await group.next() ?? false
            // 到点了：真的取消还在跑的 prepare。不取消的话，等它们的那个子任务不会结束，withTaskGroup 也就不会返回
            if !first, !Task.isCancelled { for task in tasks { task.cancel() } }
            group.cancelAll()
            return first
        }
        guard !finished, !Task.isCancelled else { return }
        for index in items.indices where items[index].state == .pending {
            let id = items[index].id
            prepareTasks.removeValue(forKey: id)?.cancel()
            items[index].prepared = PreparedText(state: .unavailable(.cancelled))
        }
    }

    // MARK: 保存

    /// ⌘⏎：有 Draft 时保存勾选的；没有时跳过模型，原样保存。
    public func save() async {
        guard canSave else { return }
        saveFailed = false
        isSaving = true
        defer { isSaving = false }
        // 网页还在抓时先等它（最多 30 秒），这样正文和快照能一起存下来
        await waitForPending()
        let currentItems = items.map { OrganizeMaterial(staged: $0.staged, prepared: $0.prepared) }
        let positions = Dictionary(uniqueKeysWithValues: currentItems.enumerated().map { ($1.staged.id, $0) })
        let hasSource = !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        let entries: [QuickAddSaveRequest.Entry]
        if drafts.isEmpty {
            guard let entry = QuickAddSaveBuilder.asIsEntry(input: inputText, materials: currentItems) else { return }
            entries = [entry]
        } else {
            entries = drafts.filter(\.isSelected).map { draft in
                // Draft 的下标指向 Organize 时的数组，换算成现在 Material 条里的下标
                let indices = draft.materialIndices.compactMap { index -> Int? in
                    guard organizedMaterials.indices.contains(index) else { return nil }
                    return positions[organizedMaterials[index].staged.id]
                }
                return .init(
                    title: draft.title, due: draft.due, detail: draft.detail,
                    materialIndices: indices, includesSource: hasSource
                )
            }
        }
        let request = QuickAddSaveRequest(entries: entries, sourceText: inputText, materials: currentItems, now: now())

        do {
            let ids = try await saver.save(request)
            clear()
            highlighter?.highlight(noteIDs: ids)
            onDidSave?()
        } catch {
            saveFailed = true
        }
    }

    // MARK: 清空

    /// 回到空白：取消一切，删 staging。保存成功后也走这里。
    public func clear() {
        organizeGeneration += 1
        organizeTask?.cancel()
        organizeTask = nil
        linkTask?.cancel()
        linkTask = nil
        for task in prepareTasks.values { task.cancel() }
        prepareTasks = [:]
        intake?.discard()
        intake = nil
        items = []
        stageFailures = []
        drafts = []
        organizedMaterials = []
        dismissedLinks = []
        saveFailed = false
        phase = .idle
        // 最后改，避免触发 didSet 之前的状态还没清完
        inputText = ""
        linkTask?.cancel()
        linkTask = nil
    }

    /// Esc：Organize 进行中只取消，面板不动；否则隐藏面板。返回 true 表示已经处理（面板不用隐藏）。
    public func handleEscape() -> Bool {
        if isOrganizing {
            cancelOrganize()
            return true
        }
        return false
    }
}
