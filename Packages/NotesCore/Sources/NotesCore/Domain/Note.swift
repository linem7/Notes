import Foundation

/// 一件要做的事（CONTEXT.md）。Material 单独存，见 `NoteWithMaterials`。
public struct Note: Identifiable, Hashable, Sendable {
    /// 完成超过这么久的 Note 连同 Material 被静默删除（SPEC §2.3）。
    public static let doneRetention: TimeInterval = 30 * 86_400

    public var id: UUID
    public var title: String
    public var due: DueDate?
    /// Markdown。
    public var detail: String
    /// nil = 未完成。
    public var doneAt: Date?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        title: String,
        due: DueDate? = nil,
        detail: String = "",
        doneAt: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.due = due
        self.detail = detail
        self.doneAt = doneAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }
}
