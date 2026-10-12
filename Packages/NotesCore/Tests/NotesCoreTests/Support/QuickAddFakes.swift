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
    /// 这些名字的 prepare 完全不响应取消，直到 `release()`。
    var stubborn: Set<String> = []
    /// 这些名字的 prepare 先睡这么久再返回结果。
    var delays: [String: Duration] = [:]
    /// `stubborn` 的放行开关：闸门而不是循环查布尔值 —— 等待期间必须真的挂起。
    private let released = Gate()
    func release() { released.open() }
    /// 测试用：闸门被查看过几次。取消之后这个数还在涨，就是退化成忙等了。
    var releaseReads: Int { released.reads }
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
        if stubborn.contains(key) {
            // 不理会取消（直到 `release()`），但不能忙等：取消之后 `Task.sleep` 会立刻抛，
            // `try?` 吞掉就变成不挂起的紧忙等，占死协作线程。
            await released.wait()
            return PreparedText(state: .unavailable(.cancelled))
        }
        if let delay = delays[key] {
            try? await Task.sleep(for: delay)
        }
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
    /// 非 nil 时 save 一直不返回（也不理会取消），直到放行。
    var hang: Gate?

    func save(_ request: QuickAddSaveRequest) async throws -> [UUID] {
        lock.withLock { _requests.append(request) }
        // 不理会取消（直到开闸），但要真的挂起 —— 同上，忙等会占死协作线程。
        if let hang { await hang.wait() }
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
