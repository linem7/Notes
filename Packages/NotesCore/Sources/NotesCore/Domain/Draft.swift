import Foundation

/// 模型根据 Quick Add 的输入生成、还没保存的 Note（CONTEXT.md；ARCHITECTURE §4.3）。
public struct Draft: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var due: DueDate?
    /// Markdown。
    public var detail: String
    /// 这条 Draft 挂哪些 Material：**从 0 开始**的下标，指向传给 `Organizer.organize` 的 `materials` 数组。
    /// 解析器已经把 prompt 里从 1 开始的序号换算好，丢掉了越界的，并且把「没写 / 写了空数组」展开成全部
    /// （`0..<count`），所以这里永远不会出现「空 = 全部」；App 直接按它挂 Material。
    public var materialIndices: [Int]
    /// 用户取消勾选的 Draft 不保存。
    public var isSelected: Bool

    public init(
        id: UUID = UUID(),
        title: String,
        due: DueDate? = nil,
        detail: String = "",
        materialIndices: [Int],
        isSelected: Bool = true
    ) {
        self.id = id
        self.title = title
        self.due = due
        self.detail = detail
        self.materialIndices = materialIndices
        self.isSelected = isSelected
    }
}
