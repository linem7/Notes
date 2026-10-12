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

    /// `materials/files/` 里现有的条目名。
    func fileNames() -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: files.filesDirectory.path)) ?? [])
    }

    /// 把 `files/` 里现有条目的修改时间拨到宽限期之外（回收会跳过刚写的文件）。
    func ageAllFiles() throws {
        let old = Date().addingTimeInterval(-(MaterialFiles.garbageGracePeriod + 60))
        for name in fileNames() {
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: files.filesDirectory.appendingPathComponent(name).path)
        }
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

    @Test(arguments: StoreKind.allCases)
    func updateKeepsCreatedAtAndDoesNotCreateNotes(kind: StoreKind) async throws {
        let f = try StoreFixture(kind)
        var n = note("n", created: 10)
        try await f.store.insert(notes: [n], materials: [])
        n.createdAt = Date(timeIntervalSinceReferenceDate: 999)   // 传进来的 createdAt 不该被写入
        n.title = "edited"
        try await f.store.update(n)
        let stored = try #require(try await f.store.allNotes().first?.note)
        #expect(stored.createdAt == Date(timeIntervalSinceReferenceDate: 10))

        let ghost = note("ghost")
        await #expect(throws: NoteStoreError.noteNotFound(ghost.id)) { try await f.store.update(ghost) }
        #expect(try await f.store.allNotes().map(\.note.title) == ["edited"])
    }

    // MARK: 删除

    @Test(arguments: StoreKind.allCases)
    func deletingTheLastReferencingNoteRemovesItsFile(kind: StoreKind) async throws {
        let f = try StoreFixture(kind)
        let n = note("n")
        try await f.store.insert(notes: [n], materials: [])
        _ = try await f.store.addMaterial(noteID: n.id, from: try f.sourceFile())
        #expect(f.fileNames().count == 1)
        try f.ageAllFiles()
        try await f.store.delete(id: n.id)
        #expect(f.fileNames().isEmpty)
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
        try f.ageAllFiles()
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
        try f.ageAllFiles()
        #expect(try await f.store.deleteExpiredDone(now: now) == 1)
        #expect(try await f.store.allNotes().map(\.note.title).sorted() == ["boundary", "open"])
        #expect(f.fileNames().isEmpty)
    }

    @Test(arguments: StoreKind.allCases)
    func deleteAllDoneKeepsOpenNotesAndRemovesDirectories(kind: StoreKind) async throws {
        let f = try StoreFixture(kind)
        let done = note("a", done: Date())
        let open = note("b")
        try await f.store.insert(notes: [done, open], materials: [])
        _ = try await f.store.addMaterial(noteID: done.id, from: try f.sourceFile("d.txt"))
        let kept = try await f.store.addMaterial(noteID: open.id, from: try f.sourceFile("o.txt"))
        try f.ageAllFiles()
        #expect(try await f.store.deleteAllDone() == 1)
        #expect(try await f.store.allNotes().map(\.note.title) == ["b"])
        #expect(f.fileNames() == [try #require(kept.storedFile)])
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
        #expect(f.fileNames().isEmpty)
    }

    /// 「先写文件、再插记录」的另一半（ARCHITECTURE §3.3）：源文件本身读不出来时，复制这一步就失败，
    /// 同样不能留下记录，也不能留下半个文件。错误类型是 `copyItem` 的实现细节，只断言抛错。
    @Test(arguments: StoreKind.allCases)
    func addMaterialWithAnUnreadableSourceThrowsAndWritesNothing(kind: StoreKind) async throws {
        let f = try StoreFixture(kind)
        let n = note("n")
        try await f.store.insert(notes: [n], materials: [])
        let missing = f.root.appendingPathComponent("没了.pdf")
        await #expect(throws: (any Error).self) {
            try await f.store.addMaterial(noteID: n.id, from: missing)
        }
        #expect(f.fileNames().isEmpty)
        #expect(try await f.store.allNotes().first?.materials.isEmpty == true)
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

    // MARK: 共享文件（ARCHITECTURE §3.3）

    /// 两条 Note 各有一行 Material，引用 `files/` 里的同一个文件。
    private func twoNotesSharingOneFile(_ f: StoreFixture) async throws -> (a: Note, b: Note, name: String) {
        let a = note("a"), b = note("b")
        let name = try f.files.importFile(from: try f.sourceFile("shared.pdf", "shared"))
        let rowA = Material(noteID: a.id, kind: .file, displayName: "shared.pdf", storedFile: name)
        let rowB = Material(noteID: b.id, kind: .file, displayName: "shared.pdf", storedFile: name)
        try await f.store.insert(notes: [a, b], materials: [rowA, rowB])
        return (a, b, name)
    }

    @Test(arguments: StoreKind.allCases)
    func referencedFileNamesIsTheUnionOfAllThreeFileColumns(kind: StoreKind) async throws {
        let f = try StoreFixture(kind)
        let n = note("n")
        try await f.store.insert(notes: [n], materials: [
            Material(noteID: n.id, kind: .file, displayName: "f", storedFile: "a.pdf"),
            Material(noteID: n.id, kind: .webPage, displayName: "w", url: "https://x.com", textFile: "b.txt", snapshotFile: "c.pdf"),
            Material(noteID: n.id, kind: .source, displayName: "Source", storedFile: "a.pdf"),
        ])
        #expect(try await f.store.referencedFileNames() == ["a.pdf", "b.txt", "c.pdf"])
    }

    @Test(arguments: StoreKind.allCases)
    func deletingOneNoteKeepsAFileAnotherNoteStillUses(kind: StoreKind) async throws {
        let f = try StoreFixture(kind)
        let (a, b, name) = try await twoNotesSharingOneFile(f)
        try f.ageAllFiles()
        try await f.store.delete(id: a.id)
        #expect(f.fileNames() == [name])
        let remaining = try await f.store.allNotes()
        #expect(remaining.map(\.note.id) == [b.id])
        let material = try #require(remaining.first?.materials.first)
        #expect(try f.files.readText(of: material, role: .stored) == "shared")
    }

    @Test(arguments: StoreKind.allCases)
    func theFileGoesWhenTheLastReferenceGoes(kind: StoreKind) async throws {
        let f = try StoreFixture(kind)
        let (a, b, _) = try await twoNotesSharingOneFile(f)
        try f.ageAllFiles()
        try await f.store.delete(id: a.id)
        #expect(f.fileNames().count == 1)
        try await f.store.delete(id: b.id)
        #expect(f.fileNames().isEmpty)
    }

    @Test(arguments: StoreKind.allCases)
    func deletingOneMaterialRowKeepsAFileAnotherRowUses(kind: StoreKind) async throws {
        let f = try StoreFixture(kind)
        let (a, _, name) = try await twoNotesSharingOneFile(f)
        try f.ageAllFiles()
        let row = try #require(try await f.store.allNotes().first { $0.id == a.id }?.materials.first)
        try await f.store.deleteMaterial(id: row.id)
        #expect(f.fileNames() == [name])
    }

    @Test(arguments: StoreKind.allCases)
    func expiredCleanupKeepsFilesSharedWithALiveNote(kind: StoreKind) async throws {
        let f = try StoreFixture(kind)
        let now = Date(timeIntervalSinceReferenceDate: 10_000_000)
        let expired = note("expired", done: now.addingTimeInterval(-Note.doneRetention - 1))
        let live = note("live")
        let name = try f.files.importFile(from: try f.sourceFile())
        try await f.store.insert(notes: [expired, live], materials: [
            Material(noteID: expired.id, kind: .file, displayName: "f", storedFile: name),
            Material(noteID: live.id, kind: .file, displayName: "f", storedFile: name),
        ])
        try f.ageAllFiles()
        #expect(try await f.store.deleteExpiredDone(now: now) == 1)
        #expect(f.fileNames() == [name])
    }

    @Test(arguments: StoreKind.allCases)
    func aFileWrittenForASaveInFlightSurvivesAnotherDeletesCollection(kind: StoreKind) async throws {
        let f = try StoreFixture(kind)
        let other = note("other")
        try await f.store.insert(notes: [other], materials: [])
        let inFlight = try f.files.writeSourceText("not yet committed")   // 文件写好了，记录还没插
        try await f.store.delete(id: other.id)                             // 别处触发的回收
        #expect(f.fileNames() == [inFlight])
    }

    @Test(arguments: StoreKind.allCases)
    func deletesSucceedEvenWhenGarbageCollectionCannotRun(kind: StoreKind) async throws {
        let f = try StoreFixture(kind)
        let a = note("a", done: Date(timeIntervalSinceReferenceDate: 1)), b = note("b"), c = note("c")
        let m = Material(noteID: b.id, kind: .source, displayName: "Source", storedFile: "s.txt")
        try await f.store.insert(notes: [a, b, c], materials: [m])
        // files 不是目录：回收列不出内容。删除是善后失败不能连累的
        try FileManager.default.createDirectory(at: f.files.materialsDirectory, withIntermediateDirectories: true)
        try Data("not a directory".utf8).write(to: f.files.filesDirectory)

        try await f.store.deleteMaterial(id: m.id)
        try await f.store.delete(id: c.id)
        #expect(try await f.store.deleteAllDone() == 1)
        #expect(try await f.store.deleteExpiredDone(now: Date()) == 0)
        #expect(try await f.store.allNotes().map(\.note.id) == [b.id])
        #expect(try await f.store.allNotes().first?.materials.isEmpty == true)
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
        // 先等初始值：observe 只保留最新值，初始值和插入后的值不等的话会被合并成一次
        try await received.waitUntilAtLeast(1)
        try await f.store.insert(notes: [note("n")], materials: [])
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

    @Test func inMemorySubscribersAreDroppedWhenTheyCancel() async throws {
        let store = InMemoryNoteStore()
        let received = Counter()
        let stream = store.observe()
        let consumer = Task { for await _ in stream { await received.increment() } }
        try await received.waitUntilAtLeast(1)
        #expect(await store.subscriberCount == 1)
        consumer.cancel()
        await consumer.value
        try await waitUntil { await store.subscriberCount == 0 }
    }

    @Test func inMemoryObserverThatIsDroppedBeforeItSubscribedDoesNotLinger() async throws {
        let store = InMemoryNoteStore()
        for _ in 0..<50 { _ = store.observe() }   // 马上丢掉，订阅登记和取消回调谁先执行都不能留下条目
        try await waitUntil { await store.subscriberCount == 0 }
    }

    @Test func grdbObservationEndsWhenTheSubscriberCancels() async throws {
        let f = try StoreFixture(.grdb)
        let store = try #require(f.store as? NoteStore)
        let received = Counter()
        let stream = store.observe()
        #expect(store.activeObservations.withLock { $0 } == 1)
        let consumer = Task { for await _ in stream { await received.increment() } }
        try await received.waitUntilAtLeast(1)
        consumer.cancel()
        await consumer.value
        try await waitUntil { store.activeObservations.withLock { $0 } == 0 }
    }
}

/// 最多等 5 秒，条件成立就返回，否则记录失败。
private func waitUntil(_ condition: () async -> Bool) async throws {
    for _ in 0..<500 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("等待超时")
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

struct NoteStoreCorruptionTests {
    private func storeWithAnUnknownMaterialKind() async throws -> NoteStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NoteStoreCorrupt-\(UUID().uuidString)")
        let store = try NoteStore(directory: root)
        let n = note("n")
        try await store.insert(notes: [n], materials: [])
        try await store.database.write { db in
            try db.execute(
                sql: "INSERT INTO material (id, noteID, kind, displayName, createdAt) VALUES (?, ?, 'hologram', 'x', 0)",
                arguments: [UUID().uuidString, n.id.uuidString]
            )
        }
        return store
    }

    @Test func anUnknownMaterialKindThrowsInsteadOfCrashing() async throws {
        let store = try await storeWithAnUnknownMaterialKind()
        await #expect(throws: StorageError.self) { try await store.allNotes() }
    }

    @Test func observeEndsTheStreamWhenTheDatabaseCannotBeRead() async throws {
        let store = try await storeWithAnUnknownMaterialKind()
        var iterator = store.observe().makeAsyncIterator()
        #expect(await iterator.next() == nil)
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
