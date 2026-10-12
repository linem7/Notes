import Foundation
import Testing
@testable import NotesCore

struct MaterialFilesTests {
    private func makeFiles() throws -> MaterialFiles {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MaterialFilesTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return MaterialFiles(root: root)
    }

    private func sourceFile(_ files: MaterialFiles, _ name: String, _ text: String = "hello") throws -> URL {
        let url = files.root.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func age(_ files: MaterialFiles, _ name: String, by seconds: TimeInterval) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-seconds)],
            ofItemAtPath: files.filesDirectory.appendingPathComponent(name).path
        )
    }

    private func entries(_ files: MaterialFiles) -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: files.filesDirectory.path)) ?? [])
    }

    // MARK: 读取

    @Test func urlIsNilWhenTheFileIsNotRecordedOrNotOnDisk() throws {
        let files = try makeFiles()
        let bare = Material(noteID: UUID(), kind: .webPage, displayName: "x")
        #expect(files.url(for: bare, role: .text) == nil)

        let recorded = Material(noteID: UUID(), kind: .webPage, displayName: "x", textFile: "gone.txt")
        #expect(files.url(for: recorded, role: .text) == nil)

        let name = try files.write(Data("body".utf8), ext: "txt")
        let present = Material(noteID: UUID(), kind: .webPage, displayName: "x", textFile: name)
        #expect(files.url(for: present, role: .text) != nil)
        #expect(files.url(for: present, role: .snapshot) == nil)
    }

    @Test func readTextReturnsContentsAndThrowsWhenMissing() throws {
        let files = try makeFiles()
        let missing = Material(noteID: UUID(), kind: .source, displayName: "Source", storedFile: "s.txt")
        #expect(throws: MaterialFilesError.self) { try files.readText(of: missing, role: .stored) }
        let name = try files.writeSourceText("原文")
        let source = Material(noteID: UUID(), kind: .source, displayName: "Source", storedFile: name)
        #expect(try files.readText(of: source, role: .stored) == "原文")
    }

    @Test func fileNamesWithPathComponentsAreNeverResolved() throws {
        let files = try makeFiles()
        _ = try files.write(Data("secret".utf8), ext: "txt")
        try Data("outside".utf8).write(to: files.materialsDirectory.appendingPathComponent("outside.txt"))
        for name in ["../outside.txt", "sub/ok.txt", "/etc/hosts", "..", "."] {
            let material = Material(noteID: UUID(), kind: .file, displayName: "x", storedFile: name)
            #expect(files.url(for: material, role: .stored) == nil, "\(name)")
        }
    }

    // MARK: 写入

    @Test func importFileCopiesWithAFreshIDKeepingTheExtension() throws {
        let files = try makeFiles()
        let source = try sourceFile(files, "合同.pdf", "pdf bytes")
        let first = try files.importFile(from: source)
        let second = try files.importFile(from: source)
        #expect(first != second)
        #expect(first.hasSuffix(".pdf"))
        #expect(UUID(uuidString: String(first.dropLast(4))) != nil)
        let material = Material(noteID: UUID(), kind: .file, displayName: "合同.pdf", storedFile: first)
        #expect(try files.readText(of: material, role: .stored) == "pdf bytes")
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test func importFileKeepsFilesWithoutAnExtensionAndCopiesBundles() throws {
        let files = try makeFiles()
        let plain = try files.importFile(from: try sourceFile(files, "README"))
        #expect(UUID(uuidString: plain) != nil)

        let bundle = files.root.appendingPathComponent("Doc.pages", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: bundle.appendingPathComponent("index.xml"))
        let name = try files.importFile(from: bundle)
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: files.filesDirectory.appendingPathComponent(name).path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
    }

    @Test func writesCanShareAFileIDForAWebPagesTextAndSnapshot() throws {
        let files = try makeFiles()
        let id = UUID()
        let text = try files.write(Data("t".utf8), ext: "txt", fileID: id)
        let pdf = try files.write(Data("p".utf8), ext: "pdf", fileID: id)
        let source = try files.writeSourceText("s", fileID: id)
        #expect(text == "\(id.uuidString).txt")
        #expect(pdf == "\(id.uuidString).pdf")
        #expect(source == "\(id.uuidString)-source.txt")
    }

    @Test func importFileKeepsOnlyTheLastExtensionAsWritten() throws {
        let files = try makeFiles()
        let archive = try files.importFile(from: try sourceFile(files, "backup.tar.gz"))
        let upper = try files.importFile(from: try sourceFile(files, "SCAN.PDF"))
        let hidden = try files.importFile(from: try sourceFile(files, ".env"))
        #expect(archive.hasSuffix(".gz") && !archive.contains("tar"))
        #expect(upper.hasSuffix(".PDF"))
        #expect(UUID(uuidString: hidden) != nil)   // 隐藏文件没有扩展名
        #expect(entries(files).count == 3)
    }

    @Test func writeRejectsExtensionsThatEscapeTheFilesDirectory() throws {
        let files = try makeFiles()
        for ext in ["txt/../../x", "a/b"] {
            #expect(throws: MaterialFilesError.self) { try files.write(Data("x".utf8), ext: ext) }
        }
        #expect(entries(files).isEmpty)
    }

    // MARK: 回收

    @Test func collectGarbageRemovesUnreferencedKeepsReferencedAndSkipsFreshOnes() throws {
        let files = try makeFiles()
        let referenced = try files.write(Data("keep".utf8), ext: "txt")
        let garbage = try files.write(Data("old".utf8), ext: "txt")
        let fresh = try files.write(Data("fresh".utf8), ext: "txt")
        let garbageBundle = try files.importFile(from: {
            let dir = files.root.appendingPathComponent("B.pages", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: dir.appendingPathComponent("i.xml"))
            return dir
        }())
        let old = MaterialFiles.garbageGracePeriod + 60
        for name in [referenced, garbage, garbageBundle] { try age(files, name, by: old) }

        let report = files.collectGarbage(referenced: [referenced])
        #expect(report.removed == 2)
        #expect(report.keptInGracePeriod == 1)
        #expect(report.failed == 0)
        #expect(entries(files) == [referenced, fresh])
    }

    @Test func gracePeriodIsMeasuredAgainstTheGivenNow() throws {
        let files = try makeFiles()
        let name = try files.write(Data("x".utf8), ext: "txt")
        #expect(files.collectGarbage(referenced: [], now: Date()).removed == 0)
        let later = Date().addingTimeInterval(MaterialFiles.garbageGracePeriod + 60)
        #expect(files.collectGarbage(referenced: [], now: later).removed == 1)
        #expect(!entries(files).contains(name))
    }

    @Test func importedFilesAreFreshEvenWhenTheSourceIsOld() throws {
        let files = try makeFiles()
        let source = try sourceFile(files, "old.txt")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000)], ofItemAtPath: source.path)
        _ = try files.importFile(from: source)
        #expect(files.collectGarbage(referenced: []).removed == 0)
    }

    @Test func importedBundlesGetTheirTopLevelModificationDateReset() throws {
        let files = try makeFiles()
        let bundle = files.root.appendingPathComponent("Old.pages", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: bundle.appendingPathComponent("index.xml"))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000)], ofItemAtPath: bundle.path)
        let name = try files.importFile(from: bundle)
        let modified = try #require(try files.filesDirectory.appendingPathComponent(name)
            .resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        #expect(abs(modified.timeIntervalSinceNow) < 60)
        #expect(files.collectGarbage(referenced: []).removed == 0)
    }

    @Test func collectGarbageWithNoFilesDirectoryIsANoOp() throws {
        let files = try makeFiles()
        #expect(files.collectGarbage(referenced: []) == MaterialFiles.GarbageReport())
    }

    @Test func collectGarbageLeavesStagingAlone() throws {
        let files = try makeFiles()
        let session = try files.makeStagingSession()
        let staged = try files.stage(data: Data("x".utf8), name: "a.txt", in: session)
        _ = files.collectGarbage(referenced: [], now: Date().addingTimeInterval(86_400))
        #expect(FileManager.default.fileExists(atPath: staged.path))
    }

    // MARK: staging

    @Test func stagingCopiesAvoidNameClashesAndClearRemovesTheSession() throws {
        let files = try makeFiles()
        let session = try files.makeStagingSession()
        let source = try sourceFile(files, "a.txt")
        let first = try files.stage(copying: source, in: session)
        let second = try files.stage(copying: source, in: session)
        let pasted = try files.stage(data: Data("png".utf8), name: "Pasted Image.png", in: session)
        #expect(first.lastPathComponent == "a.txt")
        #expect(second.lastPathComponent == "a 2.txt")
        #expect(FileManager.default.fileExists(atPath: pasted.path))

        files.clear(session)
        #expect(!FileManager.default.fileExists(atPath: session.directory.path))
    }

    @Test func clearStagingKeepsListedSessionsAndRemovesStrayFiles() throws {
        let files = try makeFiles()
        let keep = try files.makeStagingSession()
        _ = try files.makeStagingSession()
        let stray = files.stagingDirectory.appendingPathComponent("stray.txt")
        try Data("x".utf8).write(to: stray)
        let result = files.clearStaging(keeping: [keep.id])
        #expect(result.removed == 2)    // 另一个会话目录 + 根目录里的零散文件
        #expect(result.failed == 0)
        #expect(!FileManager.default.fileExists(atPath: stray.path))
        #expect(FileManager.default.fileExists(atPath: keep.directory.path))
    }
}
