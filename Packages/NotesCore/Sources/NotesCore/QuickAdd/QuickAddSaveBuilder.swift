import Foundation

/// 往 `materials/files/` 写文件，返回存储的文件名（ARCHITECTURE §3.3，共享存储）。
/// 真实实现是 `MaterialFiles` 的 `importFile(from:)`、`write(_:ext:)`、`writeSourceText(_:)`，接口定稿后接上。
public protocol MaterialFileWriting {
    func importFile(from source: URL) throws -> String
    func write(_ data: Data, ext: String) throws -> String
    func writeSourceText(_ text: String) throws -> String
}

/// 把一次保存要写的内容变成 Note 和 Material 行，并写文件。
///
/// 每个 staging 文件、每份 Source、每个 Web Page 的正文和快照在这次保存里只写一次；
/// 一次 Organize 拆成多条 Note 时，各条的 Material 行（各自的 id 和 noteID）引用同一个文件名。
public enum QuickAddSaveBuilder {
    public struct Output: Sendable, Equatable {
        public var notes: [Note]
        public var materials: [Material]
    }

    private struct WebFiles {
        var text: String?
        var snapshot: String?
    }

    public static func build(
        _ request: QuickAddSaveRequest,
        writer: some MaterialFileWriting,
        makeID: () -> UUID = { UUID() }
    ) throws -> Output {
        var storedFiles: [Int: String] = [:]
        var webFiles: [Int: WebFiles] = [:]
        var sourceFile: String?

        let sourceText = request.sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        let needsSource = request.entries.contains { $0.includesSource } && !sourceText.isEmpty
        if needsSource { sourceFile = try writer.writeSourceText(request.sourceText) }

        var notes: [Note] = []
        var rows: [Material] = []
        for (position, entry) in request.entries.enumerated() {
            // 同一时刻创建的几条 Note 保持 Draft 的顺序
            let createdAt = request.now.addingTimeInterval(Double(position) * 0.001)
            let note = Note(id: makeID(), title: entry.title, due: entry.due, detail: entry.detail, createdAt: createdAt)
            notes.append(note)

            var offset = 0.0
            func rowDate() -> Date {
                defer { offset += 0.000_001 }
                return createdAt.addingTimeInterval(offset)
            }

            if entry.includesSource, let sourceFile {
                rows.append(Material(
                    id: makeID(), noteID: note.id, kind: .source, displayName: "Source",
                    storedFile: sourceFile, createdAt: rowDate()
                ))
            }

            var seen = Set<Int>()
            for index in entry.materialIndices where request.materials.indices.contains(index) && seen.insert(index).inserted {
                let material = request.materials[index]
                switch material.staged.kind {
                case .file:
                    guard let fileURL = material.staged.fileURL else { continue }
                    if storedFiles[index] == nil { storedFiles[index] = try writer.importFile(from: fileURL) }
                    rows.append(Material(
                        id: makeID(), noteID: note.id, kind: .file, displayName: material.staged.displayName,
                        storedFile: storedFiles[index], createdAt: rowDate()
                    ))
                case .webPage:
                    if webFiles[index] == nil {
                        var files = WebFiles()
                        if case .ready(let text) = material.prepared.state {
                            files.text = try writer.write(Data(text.utf8), ext: "txt")
                        }
                        if let pdf = material.prepared.snapshotPDF {
                            files.snapshot = try writer.write(pdf, ext: "pdf")
                        }
                        webFiles[index] = files
                    }
                    let urlString = material.staged.url?.absoluteString
                    rows.append(Material(
                        id: makeID(), noteID: note.id, kind: .webPage,
                        displayName: material.prepared.title ?? urlString ?? material.staged.displayName,
                        url: urlString, textFile: webFiles[index]?.text, snapshotFile: webFiles[index]?.snapshot,
                        createdAt: rowDate()
                    ))
                case .source:
                    continue
                }
            }
        }
        return Output(notes: notes, materials: rows)
    }

    /// ⌘⏎ 在没有 Draft 时原样保存：Title 是输入的第一行（最多 80 字符），Detail 是其余部分，
    /// 没有 Due Date，所有 Material 都挂上，不生成 Source（SPEC §3.3）。只有 Material 没有文字时用第一个 Material 的名字。
    public static func asIsEntry(input: String, materials: [OrganizeMaterial]) -> QuickAddSaveRequest.Entry? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        // "\r\n" 在 Swift 里是一个 Character，不能用 split(separator: "\n")；按 isNewline 切（\n、\r、\r\n 都算）
        var title: String
        var detail: String
        if let newline = trimmed.firstIndex(where: \.isNewline) {
            title = String(trimmed[..<newline]).trimmingCharacters(in: .whitespacesAndNewlines)
            detail = String(trimmed[trimmed.index(after: newline)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            title = trimmed
            detail = ""
        }
        if title.isEmpty {
            guard let first = materials.first else { return nil }
            title = first.prepared.title ?? first.staged.displayName
        }
        if title.count > 80 {
            // 超出的部分放回 Detail 开头，不丢内容
            let cut = title.index(title.startIndex, offsetBy: 80)
            let rest = String(title[cut...]).trimmingCharacters(in: .whitespaces)
            title = String(title[..<cut])
            detail = detail.isEmpty ? rest : rest + "\n" + detail
        }
        return .init(
            title: title, due: nil, detail: detail,
            materialIndices: Array(materials.indices), includesSource: false
        )
    }
}

/// 真实的保存：写文件，再在一个事务里插入。事务失败时刚写的文件由下一次 collectGarbage 回收。
public struct QuickAddSaver<Writer: MaterialFileWriting & Sendable>: QuickAddSaving {
    private let writer: Writer
    private let store: any NoteStoring

    public init(writer: Writer, store: any NoteStoring) {
        self.writer = writer
        self.store = store
    }

    public func save(_ request: QuickAddSaveRequest) async throws -> [UUID] {
        let output = try QuickAddSaveBuilder.build(request, writer: writer)
        try await store.insert(notes: output.notes, materials: output.materials)
        return output.notes.map(\.id)
    }
}

/// `MaterialFiles` 的 `MaterialFileWriting` 实现（共享存储，写进 `materials/files/`）。
public struct MaterialFilesWriter: MaterialFileWriting, Sendable {
    private let files: MaterialFiles

    public init(files: MaterialFiles) {
        self.files = files
    }

    public func importFile(from source: URL) throws -> String { try files.importFile(from: source) }
    public func write(_ data: Data, ext: String) throws -> String { try files.write(data, ext: ext) }
    public func writeSourceText(_ text: String) throws -> String { try files.writeSourceText(text) }
}
