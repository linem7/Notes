import Foundation

/// 放在内存里的 `NoteStoring`，用于 SwiftUI 预览和测试。传了 `files` 时，
/// File 的复制和删除会真的落到磁盘；不传则只改内存。
public actor InMemoryNoteStore: NoteStoring {
    private var notes: [UUID: Note] = [:]
    private var materials: [UUID: Material] = [:]
    private var subscribers: [UUID: AsyncStream<[NoteWithMaterials]>.Continuation] = [:]
    private let files: MaterialFiles?
    private let clock: @Sendable () -> Date

    public init(
        notes: [NoteWithMaterials] = [],
        files: MaterialFiles? = nil,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.files = files
        self.clock = clock
        for item in notes {
            self.notes[item.note.id] = item.note
            for material in item.materials { materials[material.id] = material }
        }
    }

    public func allNotes() -> [NoteWithMaterials] {
        let byNote = Dictionary(grouping: materials.values, by: \.noteID)
        return notes.values
            .sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
            .map { NoteWithMaterials(note: $0, materials: (byNote[$0.id] ?? []).sortedForDisplay()) }
    }

    public nonisolated func observe() -> AsyncStream<[NoteWithMaterials]> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: [NoteWithMaterials].self, bufferingPolicy: .bufferingNewest(1)
        )
        let id = UUID()
        continuation.onTermination = { _ in
            Task { await self.unsubscribe(id) }
        }
        Task { await self.subscribe(id, continuation) }
        return stream
    }

    public func insert(notes newNotes: [Note], materials newMaterials: [Material]) throws {
        for note in newNotes where notes[note.id] != nil { throw NoteStoreError.duplicateID(note.id) }
        for material in newMaterials where materials[material.id] != nil { throw NoteStoreError.duplicateID(material.id) }
        for note in newNotes { notes[note.id] = note }
        for material in newMaterials { materials[material.id] = material }
        publish()
    }

    public func update(_ note: Note) throws {
        guard notes[note.id] != nil else { throw NoteStoreError.noteNotFound(note.id) }
        var note = note
        note.updatedAt = clock()
        notes[note.id] = note
        publish()
    }

    public func setDone(id: UUID, at date: Date?) throws {
        guard notes[id] != nil else { throw NoteStoreError.noteNotFound(id) }
        notes[id]?.doneAt = date
        publish()
    }

    public func delete(id: UUID) {
        removeNotes([id])
        publish()
    }

    public func addMaterial(noteID: UUID, from sourceURL: URL, displayName: String?) throws -> Material {
        guard notes[noteID] != nil else { throw NoteStoreError.noteNotFound(noteID) }
        let material: Material
        if let files {
            material = try files.importFile(sourceURL, noteID: noteID, displayName: displayName, now: clock())
        } else {
            material = Material(
                noteID: noteID, kind: .file,
                displayName: displayName ?? sourceURL.lastPathComponent,
                storedFile: sourceURL.lastPathComponent, createdAt: clock()
            )
        }
        materials[material.id] = material
        publish()
        return material
    }

    public func addMaterial(_ material: Material) throws {
        guard notes[material.noteID] != nil else { throw NoteStoreError.noteNotFound(material.noteID) }
        guard materials[material.id] == nil else { throw NoteStoreError.duplicateID(material.id) }
        materials[material.id] = material
        publish()
    }

    public func deleteMaterial(id: UUID) {
        guard let material = materials.removeValue(forKey: id) else { return }
        files?.removeFiles(of: material)
        publish()
    }

    public func deleteExpiredDone(now: Date) -> Int {
        let cutoff = now.addingTimeInterval(-Note.doneRetention)
        let expired = notes.values.filter { ($0.doneAt ?? .distantFuture) < cutoff }.map(\.id)
        removeNotes(expired)
        if !expired.isEmpty { publish() }
        return expired.count
    }

    public func deleteAllDone() -> Int {
        let done = notes.values.filter { $0.doneAt != nil }.map(\.id)
        removeNotes(done)
        if !done.isEmpty { publish() }
        return done.count
    }

    // MARK: 内部

    private func removeNotes(_ ids: [UUID]) {
        for id in ids {
            notes[id] = nil
            for (materialID, material) in materials where material.noteID == id { materials[materialID] = nil }
            files?.removeNoteDirectory(id)
        }
    }

    private func subscribe(_ id: UUID, _ continuation: AsyncStream<[NoteWithMaterials]>.Continuation) {
        subscribers[id] = continuation
        continuation.yield(allNotes())
    }

    private func unsubscribe(_ id: UUID) {
        subscribers[id] = nil
    }

    private func publish() {
        let snapshot = allNotes()
        for (id, continuation) in subscribers {
            if case .terminated = continuation.yield(snapshot) { subscribers[id] = nil }
        }
    }
}
