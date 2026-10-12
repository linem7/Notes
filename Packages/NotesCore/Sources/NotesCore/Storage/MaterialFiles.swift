import Foundation

public enum MaterialFileRole: Sendable {
    case stored, text, snapshot
}

public enum MaterialFilesError: Error, Equatable, Sendable {
    case missing(fileName: String)
}

/// Quick Add 期间一次会话的临时目录 `staging/<sessionID>/`（ARCHITECTURE §3.3）。
public struct StagingSession: Hashable, Sendable {
    public let id: UUID
    public let directory: URL
}

/// `materials/<noteID>/` 和 `staging/<sessionID>/` 的文件操作。`root` 在 App 里是
/// `~/Library/Application Support/com.linem7.Notes/`，测试里是临时目录。
public struct MaterialFiles: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    var materialsDirectory: URL { root.appendingPathComponent("materials", isDirectory: true) }
    var stagingDirectory: URL { root.appendingPathComponent("staging", isDirectory: true) }

    public func directory(for noteID: UUID) -> URL {
        materialsDirectory.appendingPathComponent(noteID.uuidString, isDirectory: true)
    }

    // MARK: 读取

    /// Material 某个文件的绝对路径；记录里没有这个文件，或磁盘上已经不在，返回 nil。
    public func url(for material: Material, role: MaterialFileRole) -> URL? {
        let name: String?
        switch role {
        case .stored: name = material.storedFile
        case .text: name = material.textFile
        case .snapshot: name = material.snapshotFile
        }
        guard let name else { return nil }
        let url = directory(for: material.noteID).appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// 读文本文件（Source 原文、网页正文）。文件不存在时抛 `MaterialFilesError.missing`。
    public func readText(of material: Material, role: MaterialFileRole) throws -> String {
        guard let url = url(for: material, role: role) else {
            throw MaterialFilesError.missing(fileName: material.displayName)
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: 写入 materials/<noteID>/

    public func write(_ data: Data, fileName: String, noteID: UUID) throws {
        let folder = directory(for: noteID)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: folder.appendingPathComponent(fileName), options: .atomic)
    }

    /// 复制文件或目录（`.pages` 这类 bundle 是目录）。
    public func copy(_ source: URL, fileName: String, noteID: UUID) throws {
        let folder = directory(for: noteID)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: folder.appendingPathComponent(fileName))
    }

    /// 把文件复制进 Note 目录并生成对应的 File 记录：`<materialID>.<原扩展名>`。
    public func importFile(
        _ source: URL,
        noteID: UUID,
        displayName: String? = nil,
        now: Date = Date()
    ) throws -> Material {
        let id = UUID()
        let ext = source.pathExtension
        let fileName = ext.isEmpty ? id.uuidString : "\(id.uuidString).\(ext)"
        try copy(source, fileName: fileName, noteID: noteID)
        return Material(
            id: id, noteID: noteID, kind: .file,
            displayName: displayName ?? source.lastPathComponent,
            storedFile: fileName, createdAt: now
        )
    }

    /// 删掉 Material 记录引用的全部文件。
    public func removeFiles(of material: Material) {
        for name in [material.storedFile, material.textFile, material.snapshotFile].compactMap({ $0 }) {
            try? FileManager.default.removeItem(at: directory(for: material.noteID).appendingPathComponent(name))
        }
    }

    public func removeNoteDirectory(_ noteID: UUID) {
        try? FileManager.default.removeItem(at: directory(for: noteID))
    }

    // MARK: staging

    public func makeStagingSession() throws -> StagingSession {
        let id = UUID()
        let directory = stagingDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return StagingSession(id: id, directory: directory)
    }

    /// 复制进 staging，重名时在扩展名前加序号（"a.pdf"、"a 2.pdf"）。返回副本的路径。
    public func stage(copying source: URL, in session: StagingSession) throws -> URL {
        let destination = uniqueURL(for: source.lastPathComponent, in: session.directory)
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }

    public func stage(data: Data, name: String, in session: StagingSession) throws -> URL {
        let destination = uniqueURL(for: name, in: session.directory)
        try data.write(to: destination, options: .atomic)
        return destination
    }

    public func clear(_ session: StagingSession) {
        try? FileManager.default.removeItem(at: session.directory)
    }

    private func uniqueURL(for name: String, in folder: URL) -> URL {
        var candidate = folder.appendingPathComponent(name)
        let base = candidate.deletingPathExtension().lastPathComponent
        let ext = candidate.pathExtension
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let numbered = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            candidate = folder.appendingPathComponent(numbered)
            n += 1
        }
        return candidate
    }
}
