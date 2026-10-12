import Foundation

public enum MaterialFileRole: Sendable {
    case stored, text, snapshot
}

public enum MaterialFilesError: Error, Equatable, Sendable {
    case missing(fileName: String)
    case invalidFileName(String)
}

/// Quick Add 期间一次会话的临时目录 `staging/<sessionID>/`（ARCHITECTURE §3.3）。
public struct StagingSession: Hashable, Sendable {
    public let id: UUID
    public let directory: URL
}

/// `materials/files/` 和 `staging/<sessionID>/` 的文件操作（ARCHITECTURE §3.3：所有 Material 的文件放在同一个目录，几条 Material 可以引用同一个文件）。`root` 在 App 里是
/// `~/Library/Application Support/com.linem7.Notes/`，测试里是临时目录。
public struct MaterialFiles: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// 刚写入的文件在这么久之内不会被 `collectGarbage` 回收。
    public static let garbageGracePeriod: TimeInterval = 600

    var materialsDirectory: URL { root.appendingPathComponent("materials", isDirectory: true) }
    var filesDirectory: URL { materialsDirectory.appendingPathComponent("files", isDirectory: true) }
    var stagingDirectory: URL { root.appendingPathComponent("staging", isDirectory: true) }

    /// 记录里的文件名只能是 `materials/files/` 下的一层名字，不能带路径（挡住 "../"）。
    static func isPlainFileName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && name == (name as NSString).lastPathComponent
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
        guard let name, Self.isPlainFileName(name) else { return nil }
        let url = filesDirectory.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// 读文本文件（Source 原文、网页正文）。文件不存在时抛 `MaterialFilesError.missing`。
    public func readText(of material: Material, role: MaterialFileRole) throws -> String {
        guard let url = url(for: material, role: role) else {
            throw MaterialFilesError.missing(fileName: material.displayName)
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: 写入 materials/files/

    /// 把文件（或 `.pages` 这类 bundle 目录）按原样复制进 `files/`，返回存下的文件名 `<fileID>.<原扩展名>`。
    public func importFile(from source: URL) throws -> String {
        let name = Self.storedName(fileID: UUID(), ext: source.pathExtension)
        try prepareFilesDirectory()
        let destination = filesDirectory.appendingPathComponent(name)
        try FileManager.default.copyItem(at: source, to: destination)
        markFresh(destination)
        return name
    }

    /// 写一份数据，返回文件名 `<fileID>.<ext>`。同一个 Web Page 的正文和快照传同一个 `fileID`。
    public func write(_ data: Data, ext: String, fileID: UUID = UUID()) throws -> String {
        let name = Self.storedName(fileID: fileID, ext: ext)
        guard Self.isPlainFileName(name) else { throw MaterialFilesError.invalidFileName(name) }
        try prepareFilesDirectory()
        let destination = filesDirectory.appendingPathComponent(name)
        try data.write(to: destination, options: .atomic)
        markFresh(destination)
        return name
    }

    /// 写 Source 原文，返回文件名 `<fileID>-source.txt`。
    public func writeSourceText(_ text: String, fileID: UUID = UUID()) throws -> String {
        let name = "\(fileID.uuidString)-source.txt"
        try prepareFilesDirectory()
        let destination = filesDirectory.appendingPathComponent(name)
        try Data(text.utf8).write(to: destination, options: .atomic)
        markFresh(destination)
        return name
    }

    private static func storedName(fileID: UUID, ext: String) -> String {
        ext.isEmpty ? fileID.uuidString : "\(fileID.uuidString).\(ext)"
    }

    private func prepareFilesDirectory() throws {
        try FileManager.default.createDirectory(at: filesDirectory, withIntermediateDirectories: true)
    }

    /// 复制会保留源文件的修改时间，旧文件刚写进来就会落在宽限期之外；这里把修改时间改成现在。
    private func markFresh(_ url: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

    // MARK: 回收

    public struct GarbageReport: Equatable, Sendable {
        public var removed = 0
        public var failed = 0
        /// 没人引用，但还在宽限期内，这次留着。
        public var keptInGracePeriod = 0
    }

    /// 回收 `files/` 里没有被任何 Material 行引用的条目（`referenced` 是所有行的 storedFile / textFile /
    /// snapshotFile 的并集）。修改时间在 `garbageGracePeriod`（10 分钟）之内的不删：保存 Note 是先写文件、
    /// 再在一个事务里插入记录，这中间别处触发的回收（删除另一条 Note、24 小时清理）不能把刚写好的文件当垃圾。
    /// staging 不在这里处理。
    @discardableResult
    public func collectGarbage(referenced: Set<String>, now: Date = Date()) -> GarbageReport {
        var report = GarbageReport()
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: filesDirectory, includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        for url in urls where !referenced.contains(url.lastPathComponent) {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if now.timeIntervalSince(modified) <= Self.garbageGracePeriod {
                report.keptInGracePeriod += 1
                continue
            }
            do {
                try FileManager.default.removeItem(at: url)
                report.removed += 1
            } catch {
                report.failed += 1
            }
        }
        return report
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

    /// 删掉 `staging/` 下除 `keeping` 以外的全部内容（会话目录和根目录里的零散文件）。
    func clearStaging(keeping: Set<UUID> = []) -> (removed: Int, failed: Int) {
        var removed = 0, failed = 0
        let urls = (try? FileManager.default.contentsOfDirectory(at: stagingDirectory, includingPropertiesForKeys: nil)) ?? []
        for url in urls {
            if let id = UUID(uuidString: url.lastPathComponent), keeping.contains(id) { continue }
            do {
                try FileManager.default.removeItem(at: url)
                removed += 1
            } catch {
                failed += 1
            }
        }
        return (removed, failed)
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
