import Foundation
import Testing
@testable import NotesCore

struct NotesMaintenanceTests {
    private func note(_ title: String, done: Date? = nil) -> Note {
        Note(title: title, doneAt: done)
    }

    @Test(arguments: StoreKind.allCases)
    func removesExpiredDoneNotesOrphanDirectoriesAndStaging(kind: StoreKind) async throws {
        let f = try StoreFixture(kind)
        let now = Date()
        let expired = note("expired", done: now.addingTimeInterval(-31 * 86_400))
        let live = note("live")
        try await f.store.insert(notes: [expired, live], materials: [])
        _ = try await f.store.addMaterial(noteID: live.id, from: try f.sourceFile())

        let orphan = UUID()
        try f.files.write(Data("x".utf8), fileName: "x.txt", noteID: orphan)
        let session = try f.files.makeStagingSession()
        _ = try f.files.stage(data: Data("y".utf8), name: "y.txt", in: session)

        // 孤儿目录要过了宽限期才删：把「现在」往后拨
        let later = now.addingTimeInterval(NotesMaintenance.orphanGracePeriod + 60)
        let report = await NotesMaintenance(store: f.store, files: f.files).run(now: later)

        #expect(report.expiredNotesDeleted == 1)
        #expect(report.orphanDirectoriesDeleted == 1)
        #expect(report.stagingDirectoriesDeleted == 1)
        #expect(report.failedSteps.isEmpty)
        #expect(!f.exists(orphan))
        #expect(f.exists(live.id))
        #expect(!FileManager.default.fileExists(atPath: session.directory.path))
    }

    @Test(arguments: StoreKind.allCases)
    func freshDirectoriesAreNotTreatedAsOrphans(kind: StoreKind) async throws {
        let f = try StoreFixture(kind)
        let saving = UUID()    // Quick Add 正在保存：文件已写，记录还没插入
        try f.files.write(Data("x".utf8), fileName: "x.txt", noteID: saving)
        let report = await NotesMaintenance(store: f.store, files: f.files).run(now: Date())
        #expect(report.orphanDirectoriesDeleted == 0)
        #expect(f.exists(saving))
    }

    @Test(arguments: StoreKind.allCases)
    func directoriesThatAreNotUUIDsAreLeftAlone(kind: StoreKind) async throws {
        let f = try StoreFixture(kind)
        let stray = f.files.materialsDirectory.appendingPathComponent("not-a-uuid", isDirectory: true)
        try FileManager.default.createDirectory(at: stray, withIntermediateDirectories: true)
        let later = Date().addingTimeInterval(NotesMaintenance.orphanGracePeriod + 60)
        _ = await NotesMaintenance(store: f.store, files: f.files).run(now: later)
        #expect(FileManager.default.fileExists(atPath: stray.path))
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
