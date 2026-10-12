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

        let report = await NotesMaintenance(store: f.store, files: f.files).run(.startup, now: now)

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
        let report = await NotesMaintenance(store: f.store, files: f.files).run(.startup)
        // 清理的第一步（deleteExpiredDone）已经回收过一次，所以不断言 garbageFilesDeleted 的个数
        #expect(report.failedSteps.isEmpty)
        #expect(f.fileNames() == [try #require(kept.storedFile)])
    }

    @Test(arguments: StoreKind.allCases)
    func freshlyWrittenFilesAreNotCollected(kind: StoreKind) async throws {
        let f = try StoreFixture(kind)
        let saving = try f.files.writeSourceText("x")    // Quick Add 正在保存：文件已写，记录还没插入
        let report = await NotesMaintenance(store: f.store, files: f.files).run(.periodic(keepingStaging: []))
        #expect(report.garbageFilesDeleted == 0)
        #expect(f.fileNames() == [saving])
    }

    @Test(arguments: StoreKind.allCases)
    func keepingStagingProtectsTheLiveSession(kind: StoreKind) async throws {
        let f = try StoreFixture(kind)
        let live = try f.files.makeStagingSession()
        let stale = try f.files.makeStagingSession()
        let report = await NotesMaintenance(store: f.store, files: f.files).run(.periodic(keepingStaging: [live.id]), now: Date().addingTimeInterval(MaterialFiles.garbageGracePeriod + 60))
        #expect(report.stagingDirectoriesDeleted == 1)
        #expect(FileManager.default.fileExists(atPath: live.directory.path))
        #expect(!FileManager.default.fileExists(atPath: stale.directory.path))
    }

    /// 24 小时清理读到「正在用的会话」之后，用户又粘贴了文件，Quick Add 新建了一个不在 keeping 里的会话。
    @Test(arguments: StoreKind.allCases)
    func theDailyRunSparesAFreshSessionThatIsNotInKeepingButRemovesOldOnes(kind: StoreKind) async throws {
        let f = try StoreFixture(kind)
        let fresh = try f.files.makeStagingSession()
        _ = try f.files.stage(data: Data("just pasted".utf8), name: "a.txt", in: fresh)
        let old = try f.files.makeStagingSession()
        let longAgo = Date().addingTimeInterval(-(MaterialFiles.garbageGracePeriod + 60))
        try FileManager.default.setAttributes([.modificationDate: longAgo], ofItemAtPath: old.directory.path)

        let report = await NotesMaintenance(store: f.store, files: f.files)
            .run(.periodic(keepingStaging: []))

        #expect(report.stagingDirectoriesDeleted == 1)
        #expect(FileManager.default.fileExists(atPath: fresh.directory.path))
        #expect(!FileManager.default.fileExists(atPath: old.directory.path))
    }

    @Test(arguments: StoreKind.allCases)
    func theLaunchRunRemovesFreshAndOldSessionsAlike(kind: StoreKind) async throws {
        let f = try StoreFixture(kind)
        let fresh = try f.files.makeStagingSession()
        let old = try f.files.makeStagingSession()
        let longAgo = Date().addingTimeInterval(-(MaterialFiles.garbageGracePeriod + 60))
        try FileManager.default.setAttributes([.modificationDate: longAgo], ofItemAtPath: old.directory.path)

        let report = await NotesMaintenance(store: f.store, files: f.files).run(.startup)

        #expect(report.stagingDirectoriesDeleted == 2)
        #expect(!FileManager.default.fileExists(atPath: fresh.directory.path))
        #expect(!FileManager.default.fileExists(atPath: old.directory.path))
    }

    /// ARCHITECTURE §9「不抛错：某一步失败记在 report 里，**其余步骤照常**」。
    /// 前半句是 failedSteps，后半句是 staging 照清 —— 少了后半句就测不出「照常」。
    @Test func aFailedStepIsReportedAndTheOtherStepsStillRun() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotesMaintenanceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let files = MaterialFiles(root: root)
        let session = try files.makeStagingSession()
        _ = try files.stage(data: Data("x".utf8), name: "x.txt", in: session)

        let store = FailingNoteStore(failing: [.deleteExpiredDone, .referencedFileNames])
        let report = await NotesMaintenance(store: store, files: files).run(.startup)

        #expect(report.failedSteps == ["deleteExpiredDone", "garbageCollection"])
        #expect(report.expiredNotesDeleted == 0)
        #expect(report.garbageFilesDeleted == 0)
        #expect(report.stagingDirectoriesDeleted == 1)
        #expect(!FileManager.default.fileExists(atPath: session.directory.path))
    }

    /// 回收失败有两条入口：`collectGarbage` 自己数出删不掉的文件（`garbage.failed > 0`）和 store 整个抛出来。
    /// 这条走前者：`files/` 只读时列得出条目、删不掉（`removeItem` 要父目录可写）。假设测试不是以 root 跑。
    @Test func garbageCollectionFailuresAreReportedWithoutThrowing() async throws {
        let f = try StoreFixture(.inMemory)
        _ = try f.files.writeSourceText("没人引用的文件")
        try f.ageAllFiles()
        let filesPath = f.files.filesDirectory.path
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: filesPath)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: filesPath) }

        let report = await NotesMaintenance(store: f.store, files: f.files).run(.startup)

        #expect(report.failedSteps == ["garbageCollection"])
        #expect(report.garbageFilesDeleted == 0)
        #expect(report.expiredNotesDeleted == 0)
    }
}

/// 清理路径用的桩：按需让某几步抛错，其余步骤按空库处理。
private struct FailingNoteStore: NoteStoring {
    enum Step: Hashable {
        case deleteExpiredDone
        case referencedFileNames
    }

    struct Boom: Error {}

    var failing: Set<Step> = []

    func referencedFileNames() async throws -> Set<String> {
        if failing.contains(.referencedFileNames) { throw Boom() }
        return []
    }

    func allNotes() async throws -> [NoteWithMaterials] { [] }
    func observe() -> AsyncStream<[NoteWithMaterials]> { AsyncStream { $0.finish() } }
    func insert(notes: [Note], materials: [Material]) async throws {}
    func update(_ note: Note) async throws {}
    func setDone(id: UUID, at: Date?) async throws {}
    func delete(id: UUID) async throws {}
    func addMaterial(noteID: UUID, from sourceURL: URL, displayName: String?) async throws -> Material { throw Boom() }
    func addMaterial(_ material: Material) async throws {}
    func deleteMaterial(id: UUID) async throws {}

    func deleteExpiredDone(now: Date) async throws -> Int {
        if failing.contains(.deleteExpiredDone) { throw Boom() }
        return 0
    }

    func deleteAllDone() async throws -> Int { 0 }
}
