import Foundation
import Testing

@testable import NotesCore

struct MaterialActionsTests {
    private let noteID = UUID()
    private let root: URL
    private let files: MaterialFiles

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("MaterialActionsTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        files = MaterialFiles(root: root)
    }

    /// 只创建 `existing` 里列出的文件（磁盘上有才算存在）。
    private func material(
        _ kind: MaterialKind, url: String? = nil, existing: Set<String> = []
    ) throws -> Material {
        let m = Material(
            noteID: noteID, kind: kind, displayName: "m", storedFile: "stored.bin", url: url,
            textFile: "text.txt", snapshotFile: "snapshot.pdf")
        let names = ["stored": "stored.bin", "text": "text.txt", "snapshot": "snapshot.pdf"]
        for key in existing {
            try files.write(Data("x".utf8), fileName: names[key]!, noteID: noteID)
        }
        return m
    }

    @Test func fileOpensStoredCopy() throws {
        let m = try material(.file, existing: ["stored"])
        let actions = MaterialActions(material: m, files: files)
        #expect(actions.primary == files.url(for: m, role: .stored))
        #expect(actions.primary != nil)
        #expect(actions.snapshot == nil)
        #expect(actions.inlineText == nil)
        #expect(!actions.primaryTogglesInlineText)
    }

    @Test func fileWithMissingCopyHasNothingToOpen() throws {
        let actions = MaterialActions(material: try material(.file), files: files)
        #expect(actions.primary == nil)
    }

    @Test func webPageOpensOriginalURLAndOffersSnapshotAndText() throws {
        let m = try material(.webPage, url: "https://example.com/a?b=1", existing: ["snapshot", "text"])
        let actions = MaterialActions(material: m, files: files)
        #expect(actions.primary == URL(string: "https://example.com/a?b=1"))
        #expect(actions.snapshot == files.url(for: m, role: .snapshot))
        #expect(actions.snapshot != nil)
        #expect(actions.inlineText == .text)
    }

    @Test func webPageWithoutSnapshotHidesSnapshotButton() throws {
        let m = try material(.webPage, url: "https://example.com", existing: ["text"])
        let actions = MaterialActions(material: m, files: files)
        #expect(actions.snapshot == nil)
        #expect(actions.inlineText == .text)
    }

    @Test func webPageOnlyOpensHTTP() throws {
        #expect(MaterialActions(material: try material(.webPage, url: "file:///etc/passwd"), files: files).primary == nil)
        #expect(MaterialActions(material: try material(.webPage, url: "javascript:alert(1)"), files: files).primary == nil)
        #expect(MaterialActions(material: try material(.webPage, url: nil), files: files).primary == nil)
        #expect(MaterialActions(material: try material(.webPage, url: "HTTP://Example.com"), files: files).primary != nil)
    }

    @Test func sourceExpandsInPlace() throws {
        let actions = MaterialActions(material: try material(.source, existing: ["stored"]), files: files)
        #expect(actions.primary == nil)
        #expect(actions.inlineText == .stored)
        #expect(actions.primaryTogglesInlineText)
    }

    @Test func sourceWithMissingFileCannotExpand() throws {
        let actions = MaterialActions(material: try material(.source), files: files)
        #expect(actions.inlineText == nil)
    }
}
