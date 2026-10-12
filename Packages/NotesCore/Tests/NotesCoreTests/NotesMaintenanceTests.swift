import Foundation
import Testing
@testable import NotesCore

struct NotesMaintenanceTests {
    private func note(_ title: String, done: Date? = nil) -> Note {
        Note(title: title, doneAt: done)
    }

    @Test(arguments: StoreKind.allCases)
    func removesExpiredDoneNotesUnreferencedFilesAndStaging(kind: StoreKind) async throws {
        let f = try StoreFixture(kind)
        let now = Date()
        let expired = note("expired", done: now.addingTimeInterval(-31 * 86_400))
        let live = note("live")
        try await f.store.insert(notes: [expired, live], materials: [])
        let kept = try await f.store.addMaterial(noteID: live.id, from: try f.sourceFile())
        let stray = try f.files.writeSourceText("x")    // 没有任何记录引用
        let session = try f.files.makeStagingSession()
        _ = try f.files.stage(data: Data("y".utf8), name: "y.txt", in: session)
        try f.ageAllFiles()

        let report = await NotesMaintenance(store: f.store, files: f.files).run(now: now)

        #expect(report.expiredNotesDeleted == 1)
        // 过期删除时 store 已经回收过一次，所以这里不断言 garbageFilesDeleted 的个数
        #expect(report.stagingDirectoriesDeleted == 1)
        #expect(report.failedSteps.isEmpty)
        #expect(f.fileNames() == [try #require(kept.storedFile)])
        #expect(!f.fileNames().contains(stray))
        #expect(!FileManager.default.fileExists(atPath: session.directory.path))
    }

    @Test(arguments: StoreKind.allCases)
    func maintenanceCollectsFilesLeftByACrashedSave(kind: StoreKind) async throws {
        let f = try StoreFixture(kind)
        let live = note("live")
        try await f.store.insert(notes: [live], materials: [])
        let kept = try await f.store.addMaterial(noteID: live.id, from: try f.sourceFile())
        _ = try f.files.writeSourceText("写了文件但没来得及插记录")
        try f.ageAllFiles()
        let report = await NotesMaintenance(store: f.store, files: f.files).run()
        #expect(report.garbageFilesDeleted == 1)
        #expect(f.fileNames() == [try #require(kept.storedFile)])
    }

    @Test(arguments: StoreKind.allCases)
    func freshlyWrittenFilesAreNotCollected(kind: StoreKind) async throws {
        let f = try StoreFixture(kind)
        let saving = try f.files.writeSourceText("x")    // Quick Add 正在保存：文件已写，记录还没插入
        let report = await NotesMaintenance(store: f.store, files: f.files).run(now: Date())
        #expect(report.garbageFilesDeleted == 0)
        #expect(f.fileNames() == [saving])
    }

    @Test(arguments: StoreKind.allCases)
    func keepingStagingProtectsTheLiveSession(kind: StoreKind) async throws {
        let f = try StoreFixture(kind)
        let live = try f.files.makeStagingSession()
        let stale = try f.files.makeStagingSession()
        let report = await NotesMaintenance(store: f.store, files: f.files).run(keepingStaging: [live.id])
        #expect(report.stagingDirectoriesDeleted == 1)
        #expect(FileManager.default.fileExists(atPath: live.directory.path))
        #expect(!FileManager.default.fileExists(atPath: stale.directory.path))
    }
}
