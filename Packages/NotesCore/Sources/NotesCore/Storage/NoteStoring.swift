import Foundation

public enum NoteStoreError: Error, Equatable, Sendable {
    case noteNotFound(UUID)
    case duplicateID(UUID)
}

/// Note 和 Material 的存储（ARCHITECTURE §3.2）。
///
/// 删除类操作（`delete`、`deleteMaterial`、`deleteExpiredDone`、`deleteAllDone`）提交之后会回收没人引用的文件，
/// 这一步是尽力而为：回收失败不会让删除报错，没回收掉的文件留给下一次（启动或 24 小时清理）。真实实现是 GRDB 的 `NoteStore`，
/// `InMemoryNoteStore` 用于预览和测试。
public protocol NoteStoring: Sendable {
    /// 所有 Material 行引用的文件名（storedFile / textFile / snapshotFile 的并集），给 `collectGarbage` 用。
    func referencedFileNames() async throws -> Set<String>

    /// 全部 Note，按 createdAt、id 升序；Material 按 `sortedForDisplay` 排好。
    func allNotes() async throws -> [NoteWithMaterials]

    /// 订阅时先发当前值，之后每次写入都再发一次；订阅方取消后结束。
    /// 只保留最新值：来不及消费的中间状态会被丢掉。
    func observe() -> AsyncStream<[NoteWithMaterials]>

    /// 一个事务插入。id 已存在（包括 `notes` 或 `materials` 里重复）抛 `duplicateID`；
    /// Material 的 `noteID` 既不在已有 Note 里也不在 `notes` 里时抛 `noteNotFound`。出错时什么都不写。
    func insert(notes: [Note], materials: [Material]) async throws

    /// 保存 title、due、detail，`updatedAt` 由 store 设置。**不写 `doneAt`**：完成状态只通过 `setDone` 改，
    /// 这样界面上过时的 Note 副本不会把刚完成的 Note 改回未完成。Note 不存在时抛 `noteNotFound`。
    func update(_ note: Note) async throws

    /// `at` 为 nil 表示取消完成。不改 `updatedAt`。Note 不存在时抛 `noteNotFound`。
    func setDone(id: UUID, at: Date?) async throws

    /// 只删记录（Material 级联），然后回收没人再引用的文件（§3.3）。不存在时什么也不做。
    func delete(id: UUID) async throws

    /// 把文件复制进 `materials/files/` 并插入 File 记录。插入失败时文件留给下一次回收。
    func addMaterial(noteID: UUID, from sourceURL: URL, displayName: String?) async throws -> Material

    /// 插入一条文件已经在 `materials/files/` 里的记录（Source、Web Page）。
    func addMaterial(_ material: Material) async throws

    /// 删记录，然后回收没人再引用的文件。不存在时什么也不做。
    func deleteMaterial(id: UUID) async throws

    /// 删除 `doneAt < now - 30 天` 的 Note（刚好 30 天的保留），再回收文件，返回个数。
    @discardableResult
    func deleteExpiredDone(now: Date) async throws -> Int

    /// 清空 Done 区，再回收文件，返回个数。
    @discardableResult
    func deleteAllDone() async throws -> Int
}

extension NoteStoring {
    public func addMaterial(noteID: UUID, from sourceURL: URL) async throws -> Material {
        try await addMaterial(noteID: noteID, from: sourceURL, displayName: nil)
    }
}
