import Foundation
import Testing

@testable import NotesCore

/// 不依赖 `MaterialFiles` 的目录结构：用闭包假装哪些文件在磁盘上。
struct MaterialActionsTests {
    private let noteID = UUID()

    private func actions(
        _ kind: MaterialKind, url: String? = nil, existing: Set<MaterialFileRole> = []
    ) -> MaterialActions {
        let material = Material(noteID: noteID, kind: kind, displayName: "m", url: url)
        return MaterialActions(material: material) { role in
            existing.contains(role) ? URL(fileURLWithPath: "/resolved/\(role)") : nil
        }
    }

    @Test func fileOpensStoredCopy() {
        let a = actions(.file, existing: [.stored])
        #expect(a.primary == URL(fileURLWithPath: "/resolved/stored"))
        #expect(a.snapshot == nil)
        #expect(a.inlineText == nil)
        #expect(!a.primaryTogglesInlineText)
    }

    @Test func fileWithMissingCopyHasNothingToOpen() {
        #expect(actions(.file).primary == nil)
    }

    @Test func webPageOpensOriginalURLAndOffersSnapshotAndText() {
        let a = actions(.webPage, url: "https://example.com/a?b=1", existing: [.snapshot, .text])
        #expect(a.primary == URL(string: "https://example.com/a?b=1"))
        #expect(a.snapshot == URL(fileURLWithPath: "/resolved/snapshot"))
        #expect(a.inlineText == .text)
    }

    @Test func webPageWithoutSnapshotHidesSnapshotButton() {
        let a = actions(.webPage, url: "https://example.com", existing: [.text])
        #expect(a.snapshot == nil)
        #expect(a.inlineText == .text)
    }

    @Test func webPageOnlyOpensHTTP() {
        #expect(actions(.webPage, url: "file:///etc/passwd").primary == nil)
        #expect(actions(.webPage, url: "javascript:alert(1)").primary == nil)
        #expect(actions(.webPage, url: nil).primary == nil)
        #expect(actions(.webPage, url: "HTTP://Example.com").primary != nil)
    }

    @Test func sourceExpandsInPlace() {
        let a = actions(.source, existing: [.stored])
        #expect(a.primary == nil)
        #expect(a.inlineText == .stored)
        #expect(a.primaryTogglesInlineText)
    }

    @Test func sourceWithMissingFileCannotExpand() {
        #expect(actions(.source).inlineText == nil)
    }
}
