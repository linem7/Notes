import Foundation
@testable import NotesCore

final class FakeIntake: QuickAddIntaking, @unchecked Sendable {
    let sessionID = UUID()
    private let lock = NSLock()
    private var _discarded = false
    var discarded: Bool { lock.withLock { _discarded } }
    /// 按 Material 的名字决定 prepare 的结果；没有登记的立刻 ready。
    var results: [String: PreparedText] = [:]
    /// 这些名字的 prepare 永远不返回（直到被取消）。
    var hanging: Set<String> = []
    var failingNames: Set<String> = []
    private var _cancelled: Set<String> = []
    var cancelledNames: Set<String> { lock.withLock { _cancelled } }

    func stage(fileAt source: URL) throws -> StagedMaterial {
        if failingNames.contains(source.lastPathComponent) { throw MaterialIntakeError.cannotStage(name: source.lastPathComponent) }
        return StagedMaterial(kind: .file, displayName: source.lastPathComponent, fileURL: source)
    }
    func stage(imageData: Data) throws -> StagedMaterial {
        StagedMaterial(kind: .file, displayName: "Pasted Image.png", fileURL: URL(fileURLWithPath: "/tmp/pasted.png"))
    }
    func stage(url: URL) -> StagedMaterial { StagedMaterial(kind: .webPage, displayName: url.absoluteString, url: url) }

    func prepare(_ material: StagedMaterial) async -> PreparedText {
        let key = material.url?.absoluteString ?? material.displayName
        if hanging.contains(key) {
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
            lock.withLock { _ = _cancelled.insert(key) }
            return PreparedText(state: .unavailable(.cancelled))
        }
        return results[key] ?? PreparedText(state: .ready("text of \(key)"))
    }
    func discard() { lock.withLock { _discarded = true } }
}

final class FakeOrganizer: DraftOrganizing, @unchecked Sendable {
    struct Call: Sendable { var input: String; var materials: [OrganizeMaterial] }
    private let lock = NSLock()
    private var _calls: [Call] = []
    var calls: [Call] { lock.withLock { _calls } }
    /// 每次调用返回什么；默认一条 Draft 挂全部 Material。
    var behavior: @Sendable (Call) async throws -> [Draft] = { call in
        [Draft(title: "Draft", materialIndices: Array(call.materials.indices))]
    }

    func organize(input: String, materials: [OrganizeMaterial], onProgress: (@Sendable (Int) -> Void)?) async throws -> [Draft] {
        let call = Call(input: input, materials: materials)
        lock.withLock { _calls.append(call) }
        onProgress?(12)
        return try await behavior(call)
    }
}

final class FakeSaver: QuickAddSaving, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [QuickAddSaveRequest] = []
    var requests: [QuickAddSaveRequest] { lock.withLock { _requests } }
    var error: (any Error)?

    func save(_ request: QuickAddSaveRequest) async throws -> [UUID] {
        lock.withLock { _requests.append(request) }
        if let error { throw error }
        return request.entries.map { _ in UUID() }
    }
}

@MainActor
final class FakeHighlighter: NoteHighlighting {
    var highlighted: [[UUID]] = []
    func highlight(noteIDs: [UUID]) { highlighted.append(noteIDs) }
}

/// 记录每次写入；返回的文件名是递增的假名字。
final class FakeWriter: MaterialFileWriting, @unchecked Sendable {
    var imported: [URL] = []
    var written: [(ext: String, data: Data)] = []
    var sources: [String] = []
    private var counter = 0
    private func next(_ ext: String) -> String { counter += 1; return "f\(counter).\(ext)" }

    func importFile(from source: URL) throws -> String { imported.append(source); return next(source.pathExtension) }
    func write(_ data: Data, ext: String) throws -> String { written.append((ext, data)); return next(ext) }
    func writeSourceText(_ text: String) throws -> String { sources.append(text); return next("source.txt") }
}
