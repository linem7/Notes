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

    @Test func urlIsNilWhenTheFileIsNotRecordedOrNotOnDisk() throws {
        let files = try makeFiles()
        let noteID = UUID()
        let bare = Material(noteID: noteID, kind: .webPage, displayName: "x")
        #expect(files.url(for: bare, role: .text) == nil)

        let recorded = Material(noteID: noteID, kind: .webPage, displayName: "x", textFile: "gone.txt")
        #expect(files.url(for: recorded, role: .text) == nil)

        try files.write(Data("body".utf8), fileName: "gone.txt", noteID: noteID)
        #expect(files.url(for: recorded, role: .text) != nil)
        #expect(files.url(for: recorded, role: .snapshot) == nil)
    }

    @Test func readTextReturnsContentsAndThrowsWhenMissing() throws {
        let files = try makeFiles()
        let noteID = UUID()
        let material = Material(noteID: noteID, kind: .source, displayName: "Source", storedFile: "s.txt")
        #expect(throws: MaterialFilesError.self) { try files.readText(of: material, role: .stored) }
        try files.write(Data("原文".utf8), fileName: "s.txt", noteID: noteID)
        #expect(try files.readText(of: material, role: .stored) == "原文")
    }

    @Test func importFileCopiesIntoTheNoteDirectoryKeepingTheExtension() throws {
        let files = try makeFiles()
        let noteID = UUID()
        let source = try sourceFile(files, "合同.pdf", "pdf bytes")
        let material = try files.importFile(source, noteID: noteID)
        #expect(material.kind == .file)
        #expect(material.displayName == "合同.pdf")
        #expect(material.storedFile == "\(material.id.uuidString).pdf")
        let stored = try #require(files.url(for: material, role: .stored))
        #expect(try String(contentsOf: stored, encoding: .utf8) == "pdf bytes")
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test func importFileCopiesBundleDirectories() throws {
        let files = try makeFiles()
        let bundle = files.root.appendingPathComponent("Doc.pages", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: bundle.appendingPathComponent("index.xml"))
        let material = try files.importFile(bundle, noteID: UUID())
        #expect(files.url(for: material, role: .stored) != nil)
    }

    @Test func removeFilesAndNoteDirectory() throws {
        let files = try makeFiles()
        let noteID = UUID()
        try files.write(Data("a".utf8), fileName: "a.txt", noteID: noteID)
        try files.write(Data("b".utf8), fileName: "b.pdf", noteID: noteID)
        let material = Material(noteID: noteID, kind: .webPage, displayName: "w", textFile: "a.txt", snapshotFile: "b.pdf")
        files.removeFiles(of: material)
        #expect(files.url(for: material, role: .text) == nil)
        #expect(files.url(for: material, role: .snapshot) == nil)
        #expect(FileManager.default.fileExists(atPath: files.directory(for: noteID).path))
        files.removeNoteDirectory(noteID)
        #expect(!FileManager.default.fileExists(atPath: files.directory(for: noteID).path))
    }

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

    @Test func fileNamesWithPathComponentsAreRejected() throws {
        let files = try makeFiles()
        let noteID = UUID()
        try files.write(Data("secret".utf8), fileName: "ok.txt", noteID: noteID)
        try Data("outside".utf8).write(to: files.directory(for: noteID).deletingLastPathComponent().appendingPathComponent("outside.txt"))
        for name in ["../outside.txt", "sub/ok.txt", "/etc/hosts", "..", "."] {
            let material = Material(noteID: noteID, kind: .file, displayName: "x", storedFile: name)
            #expect(files.url(for: material, role: .stored) == nil, "\(name)")
        }
        let fine = Material(noteID: noteID, kind: .file, displayName: "x", storedFile: "ok.txt")
        #expect(files.url(for: fine, role: .stored) != nil)
        let bad = Material(noteID: noteID, kind: .file, displayName: "x", storedFile: "../outside.txt")
        files.removeFiles(of: bad)
        #expect(FileManager.default.fileExists(atPath: files.directory(for: noteID).deletingLastPathComponent().appendingPathComponent("outside.txt").path))
    }

    @Test func clearStagingKeepsListedSessionsAndNoteDirectoriesIgnoreOtherNames() throws {
        let files = try makeFiles()
        let keep = try files.makeStagingSession()
        _ = try files.makeStagingSession()
        #expect(files.clearStaging(keeping: [keep.id]) == 1)
        #expect(FileManager.default.fileExists(atPath: keep.directory.path))

        let noteID = UUID()
        try files.write(Data("a".utf8), fileName: "a.txt", noteID: noteID)
        try FileManager.default.createDirectory(at: files.materialsDirectory.appendingPathComponent("junk"), withIntermediateDirectories: true)
        #expect(Set(files.noteDirectories().keys) == [noteID])
    }
}
