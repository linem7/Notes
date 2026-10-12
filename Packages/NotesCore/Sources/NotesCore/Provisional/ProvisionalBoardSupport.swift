// 临时文件（#8 阶段 A）：#3 合并前让 Board 能编译、能在 InMemoryNoteStore 上跑。
// 这里的类型和签名按 frontend-lead / backend-lead 对齐过的契约写（见 #8 PR 描述）。
// #3 合并后整个目录删除，改用 NotesCore 里的真实现；不要在别处依赖这个文件里的实现细节。
import Foundation
import Synchronization

public struct DueDate: Codable, Hashable, Sendable {
    public var day: String  // "yyyy-MM-dd"
    public var time: String?  // "HH:mm"

    public init(day: String, time: String? = nil) {
        self.day = day
        self.time = time
    }
}

public struct Note: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var due: DueDate?
    public var detail: String
    public var doneAt: Date?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(), title: String, due: DueDate? = nil, detail: String = "",
        doneAt: Date? = nil, createdAt: Date = Date(), updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.due = due
        self.detail = detail
        self.doneAt = doneAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public enum MaterialKind: String, Codable, Sendable { case source, file, webPage }

public struct Material: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var noteID: UUID
    public var kind: MaterialKind
    public var displayName: String
    public var storedFile: String?
    public var url: String?
    public var textFile: String?
    public var snapshotFile: String?
    public var createdAt: Date

    public init(
        id: UUID = UUID(), noteID: UUID, kind: MaterialKind, displayName: String,
        storedFile: String? = nil, url: String? = nil, textFile: String? = nil,
        snapshotFile: String? = nil, createdAt: Date = Date()
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

public struct NoteWithMaterials: Identifiable, Hashable, Sendable {
    public var note: Note
    public var materials: [Material]  // store 已排好序：Source 在前，其余按 createdAt 升序
    public var id: UUID { note.id }

    public init(note: Note, materials: [Material] = []) {
        self.note = note
        self.materials = materials
    }
}

public protocol NoteStoring: Sendable {
    /// 订阅即先发一次当前值，之后每次写入重发；任务取消时结束。
    func observe() -> AsyncStream<[NoteWithMaterials]>
    func update(_ note: Note) async throws
    func setDone(id: UUID, at: Date?) async throws
    func delete(id: UUID) async throws
    func addMaterial(noteID: UUID, from sourceURL: URL) async throws -> Material
    func deleteMaterial(id: UUID) async throws
}

public enum MaterialFileRole: Sendable { case stored, text, snapshot }

public protocol MaterialFileResolving: Sendable {
    /// 文件不存在时返回 nil。Web Page 的 `url` 字段不经过这里。
    func url(for material: Material, role: MaterialFileRole) -> URL?
    /// 文件不存在时 throw。
    func readText(of material: Material, role: MaterialFileRole) throws -> String
}

/// 分组和排序，规则见 SPEC §2.2。输入输出都是 `NoteWithMaterials`。
public struct BoardSections: Equatable, Sendable {
    public var overdue: [NoteWithMaterials] = []
    public var today: [NoteWithMaterials] = []
    public var upcoming: [NoteWithMaterials] = []
    public var noDate: [NoteWithMaterials] = []
    public var done: [NoteWithMaterials] = []

    /// 今天到期 + 已逾期的未完成数量（菜单栏角标）。
    public var badgeCount: Int { overdue.count + today.count }

    public init(notes: [NoteWithMaterials], today now: Date, calendar: Calendar) {
        let c = calendar.dateComponents([.year, .month, .day], from: now)
        let todayKey = String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)

        var dated: [NoteWithMaterials] = []
        for item in notes {
            if item.note.doneAt != nil {
                done.append(item)
            } else if item.note.due != nil {
                dated.append(item)
            } else {
                noDate.append(item)
            }
        }
        dated.sort { a, b in
            guard let x = a.note.due, let y = b.note.due else { return false }
            if x.day != y.day { return x.day < y.day }
            switch (x.time, y.time) {
            case let (s?, t?) where s != t: return s < t
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.note.createdAt < b.note.createdAt
            }
        }
        for item in dated {
            guard let day = item.note.due?.day else { continue }
            if day < todayKey {
                overdue.append(item)
            } else if day == todayKey {
                today.append(item)
            } else {
                upcoming.append(item)
            }
        }
        noDate.sort { $0.note.createdAt > $1.note.createdAt }
        done.sort { ($0.note.doneAt ?? .distantPast) > ($1.note.doneAt ?? .distantPast) }
    }
}

/// 内存实现，仅用于 #8 阶段 A 的开发和预览。
public final class InMemoryNoteStore: NoteStoring, Sendable {
    private struct State {
        var items: [NoteWithMaterials]
        var continuations: [UUID: AsyncStream<[NoteWithMaterials]>.Continuation] = [:]
    }

    private let state: Mutex<State>

    public init(items: [NoteWithMaterials] = []) {
        state = Mutex(State(items: items))
    }

    public func observe() -> AsyncStream<[NoteWithMaterials]> {
        let (stream, continuation) = AsyncStream<[NoteWithMaterials]>.makeStream()
        let key = UUID()
        state.withLock { state in
            state.continuations[key] = continuation
            continuation.yield(state.items)
        }
        continuation.onTermination = { [state] _ in
            _ = state.withLock { $0.continuations.removeValue(forKey: key) }
        }
        return stream
    }

    public func update(_ note: Note) async throws {
        mutate { items in
            guard let i = items.firstIndex(where: { $0.id == note.id }) else { return }
            var updated = note
            updated.updatedAt = Date()
            items[i].note = updated
        }
    }

    public func setDone(id: UUID, at: Date?) async throws {
        mutate { items in
            guard let i = items.firstIndex(where: { $0.id == id }) else { return }
            items[i].note.doneAt = at
        }
    }

    public func delete(id: UUID) async throws {
        mutate { $0.removeAll { $0.id == id } }
    }

    public func addMaterial(noteID: UUID, from sourceURL: URL) async throws -> Material {
        let material = Material(
            noteID: noteID, kind: .file, displayName: sourceURL.lastPathComponent,
            storedFile: sourceURL.lastPathComponent)
        mutate { items in
            guard let i = items.firstIndex(where: { $0.id == noteID }) else { return }
            items[i].materials.append(material)
        }
        return material
    }

    public func deleteMaterial(id: UUID) async throws {
        mutate { items in
            for i in items.indices { items[i].materials.removeAll { $0.id == id } }
        }
    }

    private func mutate(_ change: (inout [NoteWithMaterials]) -> Void) {
        state.withLock { state in
            change(&state.items)
            for continuation in state.continuations.values { continuation.yield(state.items) }
        }
    }
}
