import Foundation
import Testing

@testable import NotesCore

private struct StubFiles: MaterialFileResolving {
    var existing: Set<String>  // 例如 "stored" "text" "snapshot"

    func url(for material: Material, role: MaterialFileRole) -> URL? {
        let key: String
        switch role {
        case .stored: key = "stored"
        case .text: key = "text"
        case .snapshot: key = "snapshot"
        }
        return existing.contains(key) ? URL(fileURLWithPath: "/m/\(material.id.uuidString)/\(key)") : nil
    }

    func readText(of material: Material, role: MaterialFileRole) throws -> String { "" }
}

struct MaterialActionsTests {
    private let noteID = UUID()

    private func material(_ kind: MaterialKind, url: String? = nil) -> Material {
        Material(noteID: noteID, kind: kind, displayName: "m", url: url)
    }

    @Test func fileOpensStoredCopy() {
        let m = material(.file)
        let actions = MaterialActions(material: m, files: StubFiles(existing: ["stored"]))
        #expect(actions.primary == URL(fileURLWithPath: "/m/\(m.id.uuidString)/stored"))
        #expect(actions.snapshot == nil)
        #expect(actions.inlineText == nil)
        #expect(!actions.primaryTogglesInlineText)
    }

    @Test func fileWithMissingCopyHasNothingToOpen() {
        let actions = MaterialActions(material: material(.file), files: StubFiles(existing: []))
        #expect(actions.primary == nil)
    }

    @Test func webPageOpensOriginalURLAndOffersSnapshotAndText() {
        let m = material(.webPage, url: "https://example.com/a?b=1")
        let actions = MaterialActions(material: m, files: StubFiles(existing: ["snapshot", "text"]))
        #expect(actions.primary == URL(string: "https://example.com/a?b=1"))
        #expect(actions.snapshot == URL(fileURLWithPath: "/m/\(m.id.uuidString)/snapshot"))
        #expect(actions.inlineText == .text)
    }

    @Test func webPageWithoutSnapshotHidesSnapshotButton() {
        let m = material(.webPage, url: "https://example.com")
        let actions = MaterialActions(material: m, files: StubFiles(existing: ["text"]))
        #expect(actions.snapshot == nil)
        #expect(actions.inlineText == .text)
    }

    @Test func webPageOnlyOpensHTTP() {
        let files = StubFiles(existing: [])
        #expect(MaterialActions(material: material(.webPage, url: "file:///etc/passwd"), files: files).primary == nil)
        #expect(MaterialActions(material: material(.webPage, url: "javascript:alert(1)"), files: files).primary == nil)
        #expect(MaterialActions(material: material(.webPage, url: nil), files: files).primary == nil)
        #expect(MaterialActions(material: material(.webPage, url: "HTTP://Example.com"), files: files).primary != nil)
    }

    @Test func sourceExpandsInPlace() {
        let actions = MaterialActions(material: material(.source), files: StubFiles(existing: ["stored"]))
        #expect(actions.primary == nil)
        #expect(actions.inlineText == .stored)
        #expect(actions.primaryTogglesInlineText)
    }

    @Test func sourceWithMissingFileCannotExpand() {
        let actions = MaterialActions(material: material(.source), files: StubFiles(existing: []))
        #expect(actions.inlineText == nil)
    }
}
