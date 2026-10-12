import Foundation
import Testing
@testable import NotesCore

struct QuickAddSaveBuilderTests {
    private func file(_ name: String) -> OrganizeMaterial {
        OrganizeMaterial(
            staged: StagedMaterial(kind: .file, displayName: name, fileURL: URL(fileURLWithPath: "/staging/\(name)")),
            prepared: PreparedText(state: .ready("x"))
        )
    }

    private func page(_ url: String, title: String? = "Page", text: String? = "body", pdf: Data? = Data([1])) -> OrganizeMaterial {
        OrganizeMaterial(
            staged: StagedMaterial(kind: .webPage, displayName: url, url: URL(string: url)),
            prepared: PreparedText(state: text.map { .ready($0) } ?? .unavailable(.pageLoadFailed), title: title, snapshotPDF: pdf)
        )
    }

    private func entry(_ title: String, _ indices: [Int], source: Bool = true) -> QuickAddSaveRequest.Entry {
        .init(title: title, due: nil, detail: "", materialIndices: indices, includesSource: source)
    }

    @Test func fileSharedByTwoNotesIsWrittenOnce() throws {
        let writer = FakeWriter()
        let request = QuickAddSaveRequest(
            entries: [entry("A", [0]), entry("B", [0, 1])], sourceText: "hello",
            materials: [file("a.pdf"), file("b.txt")], now: Date(timeIntervalSince1970: 1000)
        )
        let output = try QuickAddSaveBuilder.build(request, writer: writer)

        #expect(writer.imported.count == 2)
        #expect(writer.sources == ["hello"])
        #expect(output.notes.map(\.title) == ["A", "B"])
        let aFiles = output.materials.filter { $0.noteID == output.notes[0].id && $0.kind == .file }
        let bFiles = output.materials.filter { $0.noteID == output.notes[1].id && $0.kind == .file }
        #expect(aFiles.count == 1 && bFiles.count == 2)
        #expect(aFiles[0].storedFile == bFiles.first { $0.displayName == "a.pdf" }?.storedFile)
        #expect(Set(output.materials.map(\.id)).count == output.materials.count)
    }

    @Test func sourceIsSharedAndComesFirst() throws {
        let writer = FakeWriter()
        let request = QuickAddSaveRequest(
            entries: [entry("A", []), entry("B", [])], sourceText: "chat", materials: [], now: Date()
        )
        let output = try QuickAddSaveBuilder.build(request, writer: writer)
        let sources = output.materials.filter { $0.kind == .source }
        #expect(sources.count == 2)
        #expect(sources[0].storedFile == sources[1].storedFile)
        #expect(Set(sources.map(\.noteID)).count == 2)
        #expect(writer.sources.count == 1)
    }

    @Test func noSourceWhenEntriesDontWantOneOrTextIsBlank() throws {
        let writer = FakeWriter()
        _ = try QuickAddSaveBuilder.build(
            QuickAddSaveRequest(entries: [entry("A", [], source: false)], sourceText: "chat", materials: [], now: Date()),
            writer: writer
        )
        _ = try QuickAddSaveBuilder.build(
            QuickAddSaveRequest(entries: [entry("A", [])], sourceText: "  \n", materials: [], now: Date()),
            writer: writer
        )
        #expect(writer.sources.isEmpty)
    }

    @Test func webPageWritesTextAndSnapshotOnceAndKeepsURL() throws {
        let writer = FakeWriter()
        let request = QuickAddSaveRequest(
            entries: [entry("A", [0]), entry("B", [0])], sourceText: "", materials: [page("https://example.com/a")], now: Date()
        )
        let output = try QuickAddSaveBuilder.build(request, writer: writer)
        #expect(writer.written.map(\.ext) == ["txt", "pdf"])
        let rows = output.materials.filter { $0.kind == .webPage }
        #expect(rows.count == 2)
        #expect(rows[0].url == "https://example.com/a")
        #expect(rows[0].displayName == "Page")
        #expect(rows[0].textFile == rows[1].textFile && rows[0].snapshotFile == rows[1].snapshotFile)
    }

    @Test func failedPageKeepsURLWithoutTextFile() throws {
        let writer = FakeWriter()
        let request = QuickAddSaveRequest(
            entries: [entry("A", [0])], sourceText: "", materials: [page("https://x.com", title: nil, text: nil, pdf: nil)], now: Date()
        )
        let output = try QuickAddSaveBuilder.build(request, writer: writer)
        let row = try #require(output.materials.first)
        #expect(row.textFile == nil && row.snapshotFile == nil)
        #expect(row.displayName == "https://x.com")
        #expect(writer.written.isEmpty)
    }

    @Test func outOfRangeAndDuplicateIndicesAreIgnored() throws {
        let writer = FakeWriter()
        let request = QuickAddSaveRequest(
            entries: [entry("A", [0, 0, 5, -1], source: false)], sourceText: "", materials: [file("a.pdf")], now: Date()
        )
        let output = try QuickAddSaveBuilder.build(request, writer: writer)
        #expect(output.materials.count == 1)
    }

    @Test func notesKeepDraftOrderByCreatedAt() throws {
        let request = QuickAddSaveRequest(
            entries: [entry("A", [], source: false), entry("B", [], source: false)], sourceText: "", materials: [], now: Date()
        )
        let output = try QuickAddSaveBuilder.build(request, writer: FakeWriter())
        #expect(output.notes[0].createdAt < output.notes[1].createdAt)
    }

    // MARK: 原样保存

    @Test func asIsSplitsFirstLineAndHasNoSource() throws {
        let entry = try #require(QuickAddSaveBuilder.asIsEntry(input: "Buy milk\nand eggs\nand bread", materials: [file("a.pdf")]))
        #expect(entry.title == "Buy milk")
        #expect(entry.detail == "and eggs\nand bread")
        #expect(entry.due == nil)
        #expect(entry.includesSource == false)
        #expect(entry.materialIndices == [0])
    }

    @Test func asIsLongFirstLineKeepsRestInDetail() throws {
        let line = String(repeating: "a", count: 100)
        let entry = try #require(QuickAddSaveBuilder.asIsEntry(input: line, materials: []))
        #expect(entry.title.count == 80)
        #expect(entry.detail == String(repeating: "a", count: 20))
    }

    @Test func asIsWithOnlyMaterialUsesItsName() throws {
        let entry = try #require(QuickAddSaveBuilder.asIsEntry(input: "  ", materials: [file("report.pdf")]))
        #expect(entry.title == "report.pdf")
    }

    @Test func asIsWithNothingIsNil() {
        #expect(QuickAddSaveBuilder.asIsEntry(input: " \n ", materials: []) == nil)
    }
}
