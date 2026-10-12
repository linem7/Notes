import Foundation
import Testing
@testable import NotesCore

struct InMemoryNoteStoreTests {
    private func note(_ title: String, created: TimeInterval = 0, done: Date? = nil) -> Note {
        Note(title: title, doneAt: done, createdAt: Date(timeIntervalSinceReferenceDate: created))
    }

    @Test func insertThenReadBackWithMaterialsSourceFirst() async throws {
        let store = InMemoryNoteStore()
        let n = note("n")
        let file = Material(noteID: n.id, kind: .file, displayName: "f", createdAt: Date(timeIntervalSinceReferenceDate: 1))
        let source = Material(noteID: n.id, kind: .source, displayName: "Source", createdAt: Date(timeIntervalSinceReferenceDate: 5))
        try await store.insert(notes: [n], materials: [file, source])
        let all = try await store.allNotes()
        #expect(all.count == 1)
        #expect(all[0].materials.map(\.kind) == [.source, .file])
    }

    @Test func duplicateIDsAreRejected() async throws {
        let store = InMemoryNoteStore()
        let n = note("n")
        try await store.insert(notes: [n], materials: [])
        await #expect(throws: NoteStoreError.duplicateID(n.id)) {
            try await store.insert(notes: [n], materials: [])
        }
    }

    @Test func updateSetsUpdatedAtAndMissingNotesThrow() async throws {
        let stamp = Date(timeIntervalSinceReferenceDate: 777)
        let store = InMemoryNoteStore(clock: { stamp })
        var n = note("n")
        try await store.insert(notes: [n], materials: [])
        n.title = "renamed"
        try await store.update(n)
        let stored = try await store.allNotes()[0].note
        #expect(stored.title == "renamed")
        #expect(stored.updatedAt == stamp)

        let ghost = note("ghost")
        await #expect(throws: NoteStoreError.noteNotFound(ghost.id)) { try await store.update(ghost) }
        await #expect(throws: NoteStoreError.noteNotFound(ghost.id)) { try await store.setDone(id: ghost.id, at: Date()) }
    }

    @Test func setDoneAndUndoDoNotTouchUpdatedAt() async throws {
        let store = InMemoryNoteStore(clock: { Date(timeIntervalSinceReferenceDate: 999) })
        let n = note("n")
        try await store.insert(notes: [n], materials: [])
        let when = Date(timeIntervalSinceReferenceDate: 50)
        try await store.setDone(id: n.id, at: when)
        var stored = try await store.allNotes()[0].note
        #expect(stored.doneAt == when)
        #expect(stored.updatedAt == n.updatedAt)
        try await store.setDone(id: n.id, at: nil)
        stored = try await store.allNotes()[0].note
        #expect(stored.doneAt == nil)
    }

    @Test func deleteRemovesMaterialsAndIsIdempotent() async throws {
        let store = InMemoryNoteStore()
        let n = note("n")
        try await store.insert(notes: [n], materials: [Material(noteID: n.id, kind: .source, displayName: "Source")])
        await store.delete(id: n.id)
        await store.delete(id: n.id)
        #expect(try await store.allNotes().isEmpty)
    }

    @Test func expiredDoneBoundaryIsExactly30Days() async throws {
        let store = InMemoryNoteStore()
        let now = Date(timeIntervalSinceReferenceDate: 10_000_000)
        let cutoff = now.addingTimeInterval(-Note.doneRetention)
        let expired = note("expired", done: cutoff.addingTimeInterval(-1))
        let keptAtBoundary = note("boundary", done: cutoff)
        let open = note("open")
        try await store.insert(notes: [expired, keptAtBoundary, open], materials: [])
        #expect(try await store.deleteExpiredDone(now: now) == 1)
        let titles = try await store.allNotes().map(\.note.title).sorted()
        #expect(titles == ["boundary", "open"])
    }

    @Test func deleteAllDoneKeepsOpenNotes() async throws {
        let store = InMemoryNoteStore()
        try await store.insert(notes: [note("a", done: Date()), note("b")], materials: [])
        #expect(try await store.deleteAllDone() == 1)
        #expect(try await store.allNotes().map(\.note.title) == ["b"])
    }

    @Test func deleteMaterialRemovesTheRecord() async throws {
        let store = InMemoryNoteStore()
        let n = note("n")
        let m = Material(noteID: n.id, kind: .file, displayName: "f")
        try await store.insert(notes: [n], materials: [m])
        try await store.deleteMaterial(id: m.id)
        #expect(try await store.allNotes()[0].materials.isEmpty)
    }

    @Test func addMaterialFromFileCopiesWhenFilesAreProvided() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("InMemoryNoteStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let files = MaterialFiles(root: root)
        let store = InMemoryNoteStore(files: files)
        let n = note("n")
        try await store.insert(notes: [n], materials: [])
        let source = root.appendingPathComponent("a.txt")
        try Data("hi".utf8).write(to: source)
        let material = try await store.addMaterial(noteID: n.id, from: source)
        #expect(files.url(for: material, role: .stored) != nil)
        try await store.deleteMaterial(id: material.id)
        #expect(files.url(for: material, role: .stored) == nil)
        await store.delete(id: n.id)
        #expect(!FileManager.default.fileExists(atPath: files.directory(for: n.id).path))
    }

    @Test func observeEmitsCurrentValueThenEveryWrite() async throws {
        let store = InMemoryNoteStore()
        var iterator = store.observe().makeAsyncIterator()
        let initial = await iterator.next()
        #expect(initial == [])
        let n = note("n")
        try await store.insert(notes: [n], materials: [])
        let afterInsert = await iterator.next()
        #expect(afterInsert?.map(\.note.title) == ["n"])
        try await store.setDone(id: n.id, at: Date())
        let afterDone = await iterator.next()
        #expect(afterDone?.first?.note.doneAt != nil)
        await store.delete(id: n.id)
        let afterDelete = await iterator.next()
        #expect(afterDelete == [])
    }
}
