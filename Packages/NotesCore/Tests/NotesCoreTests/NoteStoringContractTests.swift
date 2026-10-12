import Foundation
import GRDB
import Testing
@testable import NotesCore

/// 两个 `NoteStoring` 实现（内存、GRDB）跑同一套用例。
enum StoreKind: CaseIterable, Sendable, CustomTestStringConvertible {
    case inMemory, grdb
    var testDescription: String { self == .inMemory ? "InMemoryNoteStore" : "NoteStore (GRDB)" }
}

struct StoreFixture {
    let store: any NoteStoring
    let files: MaterialFiles
    let root: URL

    init(_ kind: StoreKind, clock: @escaping @Sendable () -> Date = { Date() }) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("NoteStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        files = MaterialFiles(root: root)
        switch kind {
        case .inMemory: store = InMemoryNoteStore(files: files, clock: clock)
        case .grdb: store = try NoteStore(directory: root, clock: clock)
        }
    }

    func exists(_ noteID: UUID) -> Bool {
        FileManager.default.fileExists(atPath: files.directory(for: noteID).path)
    }

    func sourceFile(_ name: String = "a.txt", _ text: String = "hi") throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }
}

private func note(_ title: String, created: TimeInterval = 0, done: Date? = nil) -> Note {
    Note(title: title, doneAt: done, createdAt: Date(timeIntervalSinceReferenceDate: created))
}

struct NoteStoringContractTests {
    @Test(arguments: StoreKind.allCases)
    func insertThenReadBackWithMaterialsSourceFirst(kind: StoreKind) async throws {
        let f = try StoreFixture(kind)
        let n = note("n")
        let file = Material(noteID: n.id, kind: .file, displayName: "f", createdAt: Date(timeIntervalSinceReferenceDate: 1))
        let source = Material(noteID: n.id, kind: .source, displayName: "Source", createdAt: Date(timeIntervalSinceReferenceDate: 5))
        try await f.store.insert(notes: [n], materials: [file, source])
        let all = try await f.store.allNotes()
        #expect(all.count == 1)
        #expect(all[0].note == n)
        #expect(all[0].materials.map(\.kind) == [.source, .file])
    }

    @Test(arguments: StoreKind.allCases)
    func notesRoundTripEveryFieldIncludingDueDate(kind: StoreKind) async throws {
        let f = try StoreFixture(kind)
        let n = Note(
            title: "T", due: DueDate(day: "2026-10-15", time: "15:00"), detail: "- a\n- b",
            doneAt: Date(timeIntervalSinceReferenceDate: 42),
            createdAt: Date(timeIntervalSinceReferenceDate: 10.5), updatedAt: Date(timeIntervalSinceReferenceDate: 11.25)
        )
        let m = Material(
            noteID: n.id, kind: .webPage, displayName: "Page", storedFile: nil, url: "https://example.com",
            textFile: "t.txt", snapshotFile: "s.pdf", createdAt: Date(timeIntervalSinceReferenceDate: 3)
        )
        try await f.store.insert(notes: [n], materials: [m])
        let all = try await f.store.allNotes()
        #expect(all.first?.note == n)
        #expect(all.first?.materials == [m])
    }

    @Test(arguments: StoreKind.allCases)
    func notesComeBackOldestFirst(kind: StoreKind) async throws {
        let f = try StoreFixture(kind)
        try await f.store.insert(notes: [note("b", created: 2), note("a", created: 1), note("c", created: 3)], materials: [])
        #expect(try await f.store.allNotes().map(\.note.title) == ["a", "b", "c"])
    }

    // MARK: 插入

    @Test(arguments: StoreKind.allCases)
    func duplicateNoteIDsAreRejected(kind: StoreKind) async throws {
        let f = try StoreFixture(kind)
        let n = note("n")
        try await f.store.insert(notes: [n], materials: [])
        await #expect(throws: NoteStoreError.duplicateID(n.id)) { try await f.store.insert(notes: [n], materials: []) }
    }

    @Test(arguments: StoreKind.allCases)
    func insertIsAtomicSoADuplicateMaterialLeavesNoNoteBehind(kind: StoreKind) async throws {
        let f = try StoreFixture(kind)
        let existing = note("existing")
        let m = Material(noteID: existing.id, kind: .source, displayName: "Source")
        try await f.store.insert(notes: [existing], materials: [m])

        let fresh = note("fresh")
        let clash = Material(id: m.id, noteID: fresh.id, kind: .source, displayName: "Source")
        await #expect(throws: NoteStoreError.duplicateID(m.id)) {
            try await f.store.insert(notes: [fresh], materials: [clash])
        }
        #expect(try await f.store.allNotes().map(\.note.title) == ["existing"])
    }

    @Test(arguments: StoreKind.allCases)
    func insertingAMaterialForAMissingNoteThrowsAndWritesNothing(kind: StoreKind) async throws {
        let f = try StoreFixture(kind)
        let n = note("n")
        let ghostID = UUID()
        await #expect(throws: NoteStoreError.noteNotFound(ghostID)) {
            try await f.store.insert(notes: [n], materials: [Material(noteID: ghostID, kind: .file, displayName: "x")])
        }
        #expect(try await f.store.allNotes().isEmpty)
    }

    @Test(arguments: StoreKind.allCases)
    func aMaterialMayReferenceANoteInsertedInTheSameCall(kind: StoreKind) async throws {
        let f = try StoreFixture(kind)
        let n = note("n")
        try await f.store.insert(notes: [n], materials: [Material(noteID: n.id, kind: .source, displayName: "Source")])
        #expect(try await f.store.allNotes().first?.materials.count == 1)
    }

    // MARK: 修改

    @Test(arguments: StoreKind.allCases)
    func updateWritesTitleDueDetailAndSetsUpdatedAt(kind: StoreKind) async throws {
        let stamp = Date(timeIntervalSinceReferenceDate: 777)
        let f = try StoreFixture(kind, clock: { stamp })
        var n = note("n")
        try await f.store.insert(notes: [n], materials: [])
        n.title = "renamed"
        n.due = DueDate(day: "2026-11-01", time: "09:30")
        n.detail = "new"
        try await f.store.update(n)
        let stored = try #require(try await f.store.allNotes().first?.note)
        #expect(stored.title == "renamed")
        #expect(stored.due == DueDate(day: "2026-11-01", time: "09:30"))
        #expect(stored.detail == "new")
        #expect(stored.updatedAt == stamp)

        n.due = nil
        try await f.store.update(n)
        #expect(try await f.store.allNotes().first?.note.due == nil)
    }

    @Test(arguments: StoreKind.allCases)
    func aStaleCopyPassedToUpdateDoesNotUncompleteANote(kind: StoreKind) async throws {
        let f = try StoreFixture(kind)
        let stale = note("n")
        try await f.store.insert(notes: [stale], materials: [])
        let when = Date(timeIntervalSinceReferenceDate: 50)
        try await f.store.setDone(id: stale.id, at: when)
        var edited = stale          // 编辑器里拿的是完成之前的副本，doneAt 为 nil
        edited.title = "edited"
        try await f.store.update(edited)
        let stored = try #require(try await f.store.allNotes().first?.note)
        #expect(stored.title == "edited")
        #expect(stored.doneAt == when)
    }

    @Test(arguments: StoreKind.allCases)
    func updateAndSetDoneOnAMissingNoteThrow(kind: StoreKind) async throws {
        let f = try StoreFixture(kind)
        let ghost = note("ghost")
        await #expect(throws: NoteStoreError.noteNotFound(ghost.id)) { try await f.store.update(ghost) }
        await #expect(throws: NoteStoreError.noteNotFound(ghost.id)) { try await f.store.setDone(id: ghost.id, at: Date()) }
    }

    @Test(arguments: StoreKind.allCases)
    func setDoneAndUndoDoNotTouchUpdatedAt(kind: StoreKind) async throws {
        let f = try StoreFixture(kind, clock: { Date(timeIntervalSinceReferenceDate: 999) })
        let n = note("n")
        try await f.store.insert(notes: [n], materials: [])
        let when = Date(timeIntervalSinceReferenceDate: 50)
        try await f.store.setDone(id: n.id, at: when)
        var stored = try #require(try await f.store.allNotes().first?.note)
        #expect(stored.doneAt == when)
        #expect(stored.updatedAt == n.updatedAt)
        try await f.store.setDone(id: n.id, at: nil)
        stored = try #require(try await f.store.allNotes().first?.note)
        #expect(stored.doneAt == nil)
    }

    // MARK: 删除

    @Test(arguments: StoreKind.allCases)
    func deletingANoteRemovesItsMaterialsAndDirectory(kind: StoreKind) async throws {
        let f = try StoreFixture(kind)
        let n = note("n")
        try await f.store.insert(notes: [n], materials: [])
        _ = try await f.store.addMaterial(noteID: n.id, from: try f.sourceFile())
        #expect(f.exists(n.id))
        try await f.store.delete(id: n.id)
        #expect(!f.exists(n.id))
        #expect(try await f.store.allNotes().isEmpty)
    }

    @Test(arguments: StoreKind.allCases)
    func deleteWithAnUnknownIDDoesNotThrow(kind: StoreKind) async throws {
        let f = try StoreFixture(kind)
        try await f.store.delete(id: UUID())
        try await f.store.deleteMaterial(id: UUID())
    }

    @Test(arguments: StoreKind.allCases)
    func deleteMaterialRemovesTheRecordAndItsFiles(kind: StoreKind) async throws {
        let f = try StoreFixture(kind)
        let n = note("n")
        try await f.store.insert(notes: [n], materials: [])
        let file = try await f.store.addMaterial(noteID: n.id, from: try f.sourceFile())
        #expect(f.files.url(for: file, role: .stored) != nil)
        try await f.store.deleteMaterial(id: file.id)
        #expect(f.files.url(for: file, role: .stored) == nil)
        #expect(try await f.store.allNotes().first?.materials.isEmpty == true)
    }

    @Test(arguments: StoreKind.allCases)
    func expiredDoneBoundaryIsExactly30Days(kind: StoreKind) async throws {
        let f = try StoreFixture(kind)
        let now = Date(timeIntervalSinceReferenceDate: 10_000_000)
        let cutoff = now.addingTimeInterval(-Note.doneRetention)
        let expired = note("expired", done: cutoff.addingTimeInterval(-1))
        let boundary = note("boundary", done: cutoff)
        try await f.store.insert(notes: [expired, boundary, note("open")], materials: [])
        _ = try await f.store.addMaterial(noteID: expired.id, from: try f.sourceFile())
        #expect(try await f.store.deleteExpiredDone(now: now) == 1)
        #expect(try await f.store.allNotes().map(\.note.title).sorted() == ["boundary", "open"])
        #expect(!f.exists(expired.id))
    }

    @Test(arguments: StoreKind.allCases)
    func deleteAllDoneKeepsOpenNotesAndRemovesDirectories(kind: StoreKind) async throws {
        let f = try StoreFixture(kind)
        let done = note("a", done: Date())
        let open = note("b")
        try await f.store.insert(notes: [done, open], materials: [])
        _ = try await f.store.addMaterial(noteID: done.id, from: try f.sourceFile("d.txt"))
        _ = try await f.store.addMaterial(noteID: open.id, from: try f.sourceFile("o.txt"))
        #expect(try await f.store.deleteAllDone() == 1)
        #expect(try await f.store.allNotes().map(\.note.title) == ["b"])
        #expect(!f.exists(done.id))
        #expect(f.exists(open.id))
    }

    // MARK: Material

    @Test(arguments: StoreKind.allCases)
    func addMaterialFromFileCopiesAndRecords(kind: StoreKind) async throws {
        let f = try StoreFixture(kind)
        let n = note("n")
        try await f.store.insert(notes: [n], materials: [])
        let material = try await f.store.addMaterial(noteID: n.id, from: try f.sourceFile("合同.pdf", "pdf"), displayName: nil)
        #expect(material.displayName == "合同.pdf")
        let stored = try #require(f.files.url(for: material, role: .stored))
        #expect(try String(contentsOf: stored, encoding: .utf8) == "pdf")
        #expect(try await f.store.allNotes().first?.materials == [material])
    }

    @Test(arguments: StoreKind.allCases)
    func addMaterialToAMissingNoteThrowsAndCopiesNothing(kind: StoreKind) async throws {
        let f = try StoreFixture(kind)
        let ghost = UUID()
        await #expect(throws: NoteStoreError.noteNotFound(ghost)) {
            try await f.store.addMaterial(noteID: ghost, from: try f.sourceFile())
        }
        #expect(!f.exists(ghost))
    }

    @Test(arguments: StoreKind.allCases)
    func addingAnExistingRecordThrowsNoteNotFoundAndDuplicateID(kind: StoreKind) async throws {
        let f = try StoreFixture(kind)
        let n = note("n")
        try await f.store.insert(notes: [n], materials: [])
        let m = Material(noteID: n.id, kind: .source, displayName: "Source", storedFile: "s.txt")
        try await f.store.addMaterial(m)
        await #expect(throws: NoteStoreError.duplicateID(m.id)) { try await f.store.addMaterial(m) }
        let orphan = Material(noteID: UUID(), kind: .source, displayName: "Source")
        await #expect(throws: NoteStoreError.noteNotFound(orphan.noteID)) { try await f.store.addMaterial(orphan) }
        #expect(try await f.store.allNotes().first?.materials == [m])
    }

    // MARK: observe

    @Test(arguments: StoreKind.allCases)
    func observeEmitsCurrentValueThenEveryWrite(kind: StoreKind) async throws {
        let f = try StoreFixture(kind)
        var iterator = f.store.observe().makeAsyncIterator()
        let initial = await iterator.next()
        #expect(initial == [])
        let n = note("n")
        try await f.store.insert(notes: [n], materials: [])
        let afterInsert = await iterator.next()
        #expect(afterInsert?.map(\.note.title) == ["n"])
        try await f.store.setDone(id: n.id, at: Date())
        let afterDone = await iterator.next()
        #expect(afterDone?.first?.note.doneAt != nil)
        try await f.store.delete(id: n.id)
        let afterDelete = await iterator.next()
        #expect(afterDelete == [])
    }

    @Test(arguments: StoreKind.allCases)
    func observeFinishesWhenTheSubscriberIsCancelled(kind: StoreKind) async throws {
        let f = try StoreFixture(kind)
        let received = Counter()
        let stream = f.store.observe()
        let consumer = Task {
            for await _ in stream { await received.increment() }
        }
        try await f.store.insert(notes: [note("n")], materials: [])
        // 初始值 + 一次插入
        try await received.waitUntilAtLeast(2)
        consumer.cancel()
        await consumer.value    // 取消后 for-await 结束；不结束这里会一直挂着
        let before = await received.value
        #expect(before >= 2)

        // 取消之后继续写入：订阅已经结束，不应再收到值
        try await f.store.insert(notes: [note("m")], materials: [])
        try await Task.sleep(for: .milliseconds(200))
        #expect(await received.value == before)
        #expect(try await f.store.allNotes().count == 2)
    }
}

private actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
    func waitUntilAtLeast(_ n: Int, timeout: Duration = .seconds(10)) async throws {
        let deadline = ContinuousClock.now + timeout
        while value < n {
            guard ContinuousClock.now < deadline else { throw CounterTimeout() }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private struct CounterTimeout: Error {}

struct NoteStoreGRDBTests {
    @Test func deletingANoteCascadesToItsMaterialRowsAndForeignKeysAreOn() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NoteStoreCascade-\(UUID().uuidString)")
        let store = try NoteStore(directory: root)
        let n = note("n")
        try await store.insert(notes: [n], materials: [
            Material(noteID: n.id, kind: .source, displayName: "Source"),
            Material(noteID: n.id, kind: .file, displayName: "f"),
        ])
        let before = try await store.database.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM material") }
        #expect(before == 2)
        try await store.delete(id: n.id)
        let after = try await store.database.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM material") }
        #expect(after == 0)
        let foreignKeys = try await store.database.read { db in try Int.fetchOne(db, sql: "PRAGMA foreign_keys") }
        #expect(foreignKeys == 1)
    }
}

struct NoteStoreReopenTests {
    @Test func dataSurvivesReopeningTheDatabase() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NoteStoreReopen-\(UUID().uuidString)")
        let n = note("kept")
        let m = Material(noteID: n.id, kind: .source, displayName: "Source", storedFile: "s.txt")
        do {
            let store = try NoteStore(directory: root)
            try await store.insert(notes: [n], materials: [m])
        }
        let reopened = try NoteStore(directory: root)
        let all = try await reopened.allNotes()
        #expect(all.map(\.note) == [n])
        #expect(all.first?.materials == [m])
    }

    @Test func rootGetsMaterialsAndStagingDirectories() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NoteStoreDirs-\(UUID().uuidString)")
        _ = try NoteStore(directory: root)
        for name in ["materials", "staging", "notes.sqlite"] {
            #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path))
        }
    }
}
