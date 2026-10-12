import Foundation

public enum NoteStoreError: Error, Equatable, Sendable {
    case noteNotFound(UUID)
    case duplicateID(UUID)
}

/// Note 和 Material 的存储（ARCHITECTURE §3.2）。真实实现是 GRDB 的 `NoteStore`，
/// `InMemoryNoteStore` 用于预览和测试。
public protocol NoteStoring: Sendable {
    /// 全部 Note，按 createdAt、id 升序；Material 按 `sortedForDisplay` 排好。
    func allNotes() async throws -> [NoteWithMaterials]

    /// 订阅时先发当前值，之后每次写入都再发一次；订阅方取消后结束。
    /// 只保留最新值：来不及消费的中间状态会被丢掉。
    func observe() -> AsyncStream<[NoteWithMaterials]>

    /// 一个事务插入。id 已存在时抛 `duplicateID`。
    func insert(notes: [Note], materials: [Material]) async throws

    /// 保存修改，`updatedAt` 由 store 设置。Note 不存在时抛 `noteNotFound`。
    func update(_ note: Note) async throws

    /// `at` 为 nil 表示取消完成。不改 `updatedAt`。Note 不存在时抛 `noteNotFound`。
    func setDone(id: UUID, at: Date?) async throws

    /// 删记录，再删 `materials/<noteID>/`。不存在时什么也不做。
    func delete(id: UUID) async throws

    /// 把文件复制进 `materials/<noteID>/` 并插入 File 记录，一次完成。
    func addMaterial(noteID: UUID, from sourceURL: URL, displayName: String?) async throws -> Material

    /// 插入一条文件已经在 `materials/<noteID>/` 里的记录（Source、Web Page）。
    func addMaterial(_ material: Material) async throws

    /// 删记录和它的文件。不存在时什么也不做。
    func deleteMaterial(id: UUID) async throws

    /// 删除 `doneAt < now - 30 天` 的 Note（刚好 30 天的保留），返回个数。
    @discardableResult
    func deleteExpiredDone(now: Date) async throws -> Int

    /// 清空 Done 区，返回个数。
    @discardableResult
    func deleteAllDone() async throws -> Int
}

extension NoteStoring {
    public func addMaterial(noteID: UUID, from sourceURL: URL) async throws -> Material {
        try await addMaterial(noteID: noteID, from: sourceURL, displayName: nil)
    }
}
