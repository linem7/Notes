import Foundation

/// Board 的交互状态：展开、编辑、选中、新 Note 高亮。纯值类型，便于测试；App 层的 BoardModel 持有它。
public struct BoardState: Equatable, Sendable {
    public private(set) var expandedID: UUID?
    public private(set) var editingID: UUID?
    public private(set) var selectedID: UUID?
    public var isDoneExpanded = false

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

    /// 只有已展开的行能进入编辑。
    @discardableResult
    public mutating func beginEditing(_ id: UUID) -> Bool {
        guard expandedID == id, editingID == nil else { return false }
        editingID = id
        return true
    }

    public mutating func endEditing() {
        editingID = nil
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
    @discardableResult
    public mutating func reconcile(existing: Set<UUID>) -> Set<UUID> {
        if let id = expandedID, !existing.contains(id) { expandedID = nil }
        if let id = editingID, !existing.contains(id) { editingID = nil }
        if let id = selectedID, !existing.contains(id) { selectedID = nil }
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
