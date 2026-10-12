import Foundation
import GRDB

/// 本地存储（ARCHITECTURE §3.2）：GRDB 数据库加 `materials/` 目录。
///
/// 目录结构：`<directory>/notes.sqlite`、`<directory>/materials/files/`、`<directory>/staging/`。
/// App 里 directory 是 `~/Library/Application Support/com.linem7.Notes/`。
public final class NoteStore: NoteStoring, Sendable {
    /// 测试里直接查表用（比如确认外键开着、级联删除生效）。
    let database: DatabasePool
    private let files: MaterialFiles
    private let clock: @Sendable () -> Date

    public init(directory: URL, clock: @escaping @Sendable () -> Date = { Date() }) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        files = MaterialFiles(root: directory)
        try FileManager.default.createDirectory(at: files.materialsDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: files.stagingDirectory, withIntermediateDirectories: true)
        database = try DatabasePool(path: directory.appendingPathComponent("notes.sqlite").path)
        self.clock = clock
        try Self.migrator.migrate(database)
    }

    /// 读 Material 文件用的 `MaterialFiles`（根目录和这个 store 相同）。
    public var materialFiles: MaterialFiles { files }

    // MARK: 读取

    public func allNotes() async throws -> [NoteWithMaterials] {
        try await database.read { db in try Self.fetchAll(db) }
    }

    public func observe() -> AsyncStream<[NoteWithMaterials]> {
        let observation = ValueObservation.tracking { db in try Self.fetchAll(db) }
        let (stream, continuation) = AsyncStream.makeStream(
            of: [NoteWithMaterials].self, bufferingPolicy: .bufferingNewest(1)
        )
        let database = database
        let task = Task {
            do {
                for try await value in observation.values(in: database, bufferingPolicy: .bufferingNewest(1)) {
                    continuation.yield(value)
                }
            } catch {
                // 读库失败：结束这个流，订阅方按「流结束」处理
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    // MARK: 写入

    public func insert(notes: [Note], materials: [Material]) async throws {
        try await database.write { db in
            for note in notes {
                guard try !Self.noteExists(note.id, db) else { throw NoteStoreError.duplicateID(note.id) }
                try Self.insert(note, db)
            }
            for material in materials {
                guard try Self.noteExists(material.noteID, db) else { throw NoteStoreError.noteNotFound(material.noteID) }
                guard try !Self.materialExists(material.id, db) else { throw NoteStoreError.duplicateID(material.id) }
                try Self.insert(material, db)
            }
        }
    }

    public func update(_ note: Note) async throws {
        var note = note
        note.updatedAt = clock()
        let updated = note
        try await database.write { db in
            try db.execute(
                sql: """
                    UPDATE note SET title = ?, dueDay = ?, dueTime = ?, detail = ?, updatedAt = ?
                    WHERE id = ?
                    """,
                arguments: [
                    updated.title, updated.due?.day, updated.due?.time, updated.detail,
                    updated.updatedAt.timeIntervalSinceReferenceDate, updated.id.uuidString,
                ]
            )
            if db.changesCount == 0 { throw NoteStoreError.noteNotFound(updated.id) }
        }
    }

    public func setDone(id: UUID, at date: Date?) async throws {
        try await database.write { db in
            try db.execute(
                sql: "UPDATE note SET doneAt = ? WHERE id = ?",
                arguments: [date?.timeIntervalSinceReferenceDate, id.uuidString]
            )
            if db.changesCount == 0 { throw NoteStoreError.noteNotFound(id) }
        }
    }

    public func delete(id: UUID) async throws {
        try await database.write { db in
            try db.execute(sql: "DELETE FROM note WHERE id = ?", arguments: [id.uuidString])
        }
        await collectGarbage()
    }

    public func addMaterial(noteID: UUID, from sourceURL: URL, displayName: String?) async throws -> Material {
        guard try await database.read({ db in try Self.noteExists(noteID, db) }) else {
            throw NoteStoreError.noteNotFound(noteID)
        }
        let material = Material(
            noteID: noteID, kind: .file,
            displayName: displayName ?? sourceURL.lastPathComponent,
            storedFile: try files.importFile(from: sourceURL), createdAt: clock()
        )
        // 插入失败时文件留着，下一次 collectGarbage 回收
        try await addMaterial(material)
        return material
    }

    public func addMaterial(_ material: Material) async throws {
        try await insert(notes: [], materials: [material])
    }

    public func deleteMaterial(id: UUID) async throws {
        try await database.write { db in
            try db.execute(sql: "DELETE FROM material WHERE id = ?", arguments: [id.uuidString])
        }
        await collectGarbage()
    }

    public func referencedFileNames() async throws -> Set<String> {
        try await database.read { db in
            var names: Set<String> = []
            for row in try Row.fetchAll(db, sql: "SELECT storedFile, textFile, snapshotFile FROM material") {
                for column in ["storedFile", "textFile", "snapshotFile"] {
                    if let name: String = row[column] { names.insert(name) }
                }
            }
            return names
        }
    }

    /// 回收没人引用的文件。这是删除提交之后的善后：读引用失败就算了，留给下一次回收，不能让已经成功的删除变成报错。
    /// 用真实时间判断宽限期（文件的修改时间是真实时间，和注入的 clock 无关）。
    private func collectGarbage() async {
        guard let referenced = try? await referencedFileNames() else { return }
        files.collectGarbage(referenced: referenced, now: Date())
    }

    @discardableResult
    public func deleteExpiredDone(now: Date) async throws -> Int {
        let cutoff = now.addingTimeInterval(-Note.doneRetention).timeIntervalSinceReferenceDate
        return try await deleteNotes(where: "doneAt IS NOT NULL AND doneAt < ?", arguments: [cutoff])
    }

    @discardableResult
    public func deleteAllDone() async throws -> Int {
        try await deleteNotes(where: "doneAt IS NOT NULL", arguments: [])
    }

    private func deleteNotes(where condition: String, arguments: StatementArguments) async throws -> Int {
        let count = try await database.write { db -> Int in
            try db.execute(sql: "DELETE FROM note WHERE \(condition)", arguments: arguments)
            return db.changesCount
        }
        await collectGarbage()
        return count
    }
}

// MARK: - 表结构和行映射

extension NoteStore {
    /// 时间一律存 `timeIntervalSinceReferenceDate`（同 Chatbot）。表结构见 ARCHITECTURE §3.2。
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "note") { t in
                t.primaryKey("id", .text)
                t.column("title", .text).notNull()
                t.column("dueDay", .text)
                t.column("dueTime", .text)
                t.column("detail", .text).notNull()
                t.column("doneAt", .double)
                t.column("createdAt", .double).notNull()
                t.column("updatedAt", .double).notNull()
            }
            try db.create(table: "material") { t in
                t.primaryKey("id", .text)
                t.column("noteID", .text).notNull().indexed().references("note", onDelete: .cascade)
                t.column("kind", .text).notNull()
                t.column("displayName", .text).notNull()
                t.column("storedFile", .text)
                t.column("url", .text)
                t.column("textFile", .text)
                t.column("snapshotFile", .text)
                t.column("createdAt", .double).notNull()
            }
        }
        return migrator
    }

    static func fetchAll(_ db: Database) throws -> [NoteWithMaterials] {
        let notes = try Row.fetchAll(db, sql: "SELECT * FROM note ORDER BY createdAt, id").map(note(from:))
        let materials = try Row.fetchAll(db, sql: "SELECT * FROM material").map(material(from:))
        let byNote = Dictionary(grouping: materials, by: \.noteID)
        return notes.map { NoteWithMaterials(note: $0, materials: (byNote[$0.id] ?? []).sortedForDisplay()) }
    }

    private static func noteExists(_ id: UUID, _ db: Database) throws -> Bool {
        try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM note WHERE id = ?)", arguments: [id.uuidString]) ?? false
    }

    private static func materialExists(_ id: UUID, _ db: Database) throws -> Bool {
        try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM material WHERE id = ?)", arguments: [id.uuidString]) ?? false
    }

    private static func insert(_ note: Note, _ db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO note (id, title, dueDay, dueTime, detail, doneAt, createdAt, updatedAt)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                note.id.uuidString, note.title, note.due?.day, note.due?.time, note.detail,
                note.doneAt?.timeIntervalSinceReferenceDate,
                note.createdAt.timeIntervalSinceReferenceDate, note.updatedAt.timeIntervalSinceReferenceDate,
            ]
        )
    }

    private static func insert(_ material: Material, _ db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO material (id, noteID, kind, displayName, storedFile, url, textFile, snapshotFile, createdAt)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                material.id.uuidString, material.noteID.uuidString, material.kind.rawValue, material.displayName,
                material.storedFile, material.url, material.textFile, material.snapshotFile,
                material.createdAt.timeIntervalSinceReferenceDate,
            ]
        )
    }

    private static func note(from row: Row) throws -> Note {
        let dueDay: String? = row["dueDay"]
        let doneAt: Double? = row["doneAt"]
        return Note(
            id: try uuid(row["id"]),
            title: row["title"],
            due: dueDay.map { DueDate(day: $0, time: row["dueTime"]) },
            detail: row["detail"],
            doneAt: doneAt.map(Date.init(timeIntervalSinceReferenceDate:)),
            createdAt: Date(timeIntervalSinceReferenceDate: row["createdAt"]),
            updatedAt: Date(timeIntervalSinceReferenceDate: row["updatedAt"])
        )
    }

    private static func material(from row: Row) throws -> Material {
        let kindValue: String = row["kind"]
        guard let kind = MaterialKind(rawValue: kindValue) else {
            throw StorageError.corruptRow("未知的 kind：\(kindValue)")
        }
        return Material(
            id: try uuid(row["id"]),
            noteID: try uuid(row["noteID"]),
            kind: kind,
            displayName: row["displayName"],
            storedFile: row["storedFile"],
            url: row["url"],
            textFile: row["textFile"],
            snapshotFile: row["snapshotFile"],
            createdAt: Date(timeIntervalSinceReferenceDate: row["createdAt"])
        )
    }

    private static func uuid(_ string: String) throws -> UUID {
        guard let uuid = UUID(uuidString: string) else { throw StorageError.corruptRow("不是 UUID：\(string)") }
        return uuid
    }
}

enum StorageError: Error {
    case corruptRow(String)
}
