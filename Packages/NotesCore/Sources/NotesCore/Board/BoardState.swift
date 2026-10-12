import Foundation

/// Board 的交互状态：展开、编辑、选中、新 Note 高亮。纯值类型，便于测试；App 层的 BoardModel 持有它。
public struct BoardState: Equatable, Sendable {
    public private(set) var expandedID: UUID?
    public private(set) var editingID: UUID?
    public private(set) var selectedID: UUID?
    public var isDoneExpanded = false

    /// 编辑器（NoteEditor）是否在界面上、能提交内容。`beginEditing` 之后到编辑器出现之前为 false。
    public private(set) var editorAvailable = false
    /// 编辑中点了别的行：等保存成功（或确认没有改动）后再去展开它。
    private var pendingToggleID: UUID?

    /// 已出现在列表里、正在显示高亮的 Note。
    public private(set) var highlightedIDs: Set<UUID> = []
    /// 已请求高亮、但 observe 还没把它们发过来的 Note（避免保存与刷新之间的竞态）。
    private var pendingHighlightIDs: Set<UUID> = []

    public init() {}

    // MARK: 展开 / 选中 / 编辑

    /// 点击一行：展开它、收起其他行，并选中。编辑中不允许切换，返回 false。
    @discardableResult
    public mutating func toggleExpanded(_ id: UUID) -> Bool {
        guard editingID == nil else { return false }
        expandedID = (expandedID == id) ? nil : id
        selectedID = id
        return true
    }

    /// 用户点了一行。没在编辑时直接展开/收起，返回 true；编辑器已经不在时（拿不到内容）结束编辑再展开，返回 true。
    /// 编辑器还在时返回 false：调用方要先让编辑器提交，保存成功后由 `saveFinished` 去展开这一行。
    @discardableResult
    public mutating func requestToggle(_ id: UUID) -> Bool {
        if editingID != nil {
            guard !editorAvailable else {
                pendingToggleID = id
                return false
            }
            endEditing()
        }
        return toggleExpanded(id)
    }

    /// 只有已展开的行能进入编辑。
    @discardableResult
    public mutating func beginEditing(_ id: UUID) -> Bool {
        guard expandedID == id, editingID == nil else { return false }
        editingID = id
        editorAvailable = false
        return true
    }

    /// 结束编辑（不保存、不展开别的行）。
    public mutating func endEditing() {
        editingID = nil
        pendingToggleID = nil
    }

    /// Esc：放弃修改。任何时候都能退出编辑，也取消待执行的展开。
    public mutating func cancelEditing() {
        endEditing()
    }

    /// 失焦时没有需要保存的改动：结束编辑，并去展开刚才点的那一行（如果有）。
    public mutating func finishEditingWithoutChanges() {
        let next = pendingToggleID
        endEditing()
        if let next { toggleExpanded(next) }
    }

    /// 保存（`update`）完成。成功：结束编辑，并展开刚才点的那一行；失败：留在编辑状态，用户输入还在，
    /// 待执行的展开作废（再点一次会重试保存）。`id` 不是正在编辑的行（已经 Esc 或换了行）时什么也不做。
    public mutating func saveFinished(id: UUID, succeeded: Bool) {
        guard editingID == id else { return }
        if succeeded {
            finishEditingWithoutChanges()
        } else {
            pendingToggleID = nil
        }
    }

    /// NoteEditor 出现/消失时调用。编辑器消失后拿不到内容，正在进行的编辑只能结束（未保存的修改丢失）。
    public mutating func setEditorAvailable(_ available: Bool) {
        editorAvailable = available
        if !available, editingID != nil { endEditing() }
    }

    /// ⌫ 只在选中了某行、且没有在编辑时作用于它。
    public var deletableID: UUID? {
        editingID == nil ? selectedID : nil
    }

    // MARK: 高亮

    /// 新 Note 保存后调用。新的请求替换旧的。
    public mutating func requestHighlight(_ ids: [UUID]) {
        highlightedIDs = []
        pendingHighlightIDs = Set(ids)
    }

    /// 列表刷新后调用：清掉已不存在的行的状态，把已出现的待高亮 id 变成高亮。
    /// 返回本次新开始高亮的 id，调用方为它们计时后调用 `expireHighlight`。
    ///
    /// `visible` 是界面上看得到的行（例如折叠着的 Done 区里的行不在其中），默认等于 `existing`。
    /// 看不到的行不能保持展开、编辑或选中（否则 ⌫ 会删掉看不见的 Note，编辑状态也会卡住）。
    @discardableResult
    public mutating func reconcile(existing: Set<UUID>, visible: Set<UUID>? = nil) -> Set<UUID> {
        let visible = visible.map { $0.intersection(existing) } ?? existing
        if let id = expandedID, !visible.contains(id) { expandedID = nil }
        if let id = editingID, !visible.contains(id) || expandedID != id { endEditing() }
        if let id = selectedID, !visible.contains(id) { selectedID = nil }
        highlightedIDs.formIntersection(existing)

        let appeared = pendingHighlightIDs.intersection(existing)
        pendingHighlightIDs.subtract(appeared)
        highlightedIDs.formUnion(appeared)
        return appeared
    }

    public mutating func expireHighlight(_ ids: Set<UUID>) {
        highlightedIDs.subtract(ids)
    }
}
