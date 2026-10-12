import Foundation

public enum MaterialKind: String, Codable, Hashable, Sendable {
    case source, file, webPage
}

/// 挂在 Note 上的原始资料（ARCHITECTURE §3.1、§3.3）。文件名都相对 `materials/files/`，几条 Material 可以引用同一个文件。
public struct Material: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var noteID: UUID
    public var kind: MaterialKind
    /// 文件名 / 网页标题（抓取失败时是 URL）/ "Source"。
    public var displayName: String
    /// File 的副本、Source 的 .txt。
    public var storedFile: String?
    /// Web Page 的 URL。
    public var url: String?
    /// Web Page 抽出的正文 .txt。
    public var textFile: String?
    /// Web Page 的 PDF 快照。
    public var snapshotFile: String?
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        noteID: UUID,
        kind: MaterialKind,
        displayName: String,
        storedFile: String? = nil,
        url: String? = nil,
        textFile: String? = nil,
        snapshotFile: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.noteID = noteID
        self.kind = kind
        self.displayName = displayName
        self.storedFile = storedFile
        self.url = url
        self.textFile = textFile
        self.snapshotFile = snapshotFile
        self.createdAt = createdAt
    }
}

extension Sequence where Element == Material {
    /// 展示顺序：Source 在前，其余按 createdAt 升序，再按 id 稳定排序。
    public func sortedForDisplay() -> [Material] {
        sorted { lhs, rhs in
            if (lhs.kind == .source) != (rhs.kind == .source) { return lhs.kind == .source }
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }
}

/// Board 一次拿到的一条 Note 和它的 Material（已按 `sortedForDisplay` 排好）。
public struct NoteWithMaterials: Identifiable, Hashable, Sendable {
    public var note: Note
    public var materials: [Material]
    public var id: UUID { note.id }

    public init(note: Note, materials: [Material] = []) {
        self.note = note
        self.materials = materials
    }
}
