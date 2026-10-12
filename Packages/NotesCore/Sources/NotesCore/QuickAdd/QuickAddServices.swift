import Foundation

/// Organize 失败的原因里，App 要单独处理的那一种：没有可用的 Connection / Default Model / key。
public enum OrganizeSetupError: Error, Equatable, Sendable {
    case noConnection
}

/// QuickAddStore 需要的 Organize。真实实现包着 `Organizer`（#6 合并后加），测试里换成假的。
/// 出错抛 `ChatError` 或 `OrganizeSetupError`；任务被取消时抛 `CancellationError`。
/// 返回的 Draft 的 `materialIndices` 是 `materials` 数组的 0 基下标。
public protocol DraftOrganizing: Sendable {
    func organize(
        input: String,
        materials: [OrganizeMaterial],
        onProgress: (@Sendable (Int) -> Void)?
    ) async throws -> [Draft]
}

/// QuickAddStore 需要的 Intake：暂存文件、准备 Readable Text、丢弃整个 staging 会话。
public protocol QuickAddIntaking: Sendable {
    /// `staging/<sessionID>/` 的 id。
    var sessionID: UUID { get }
    func stage(fileAt source: URL) throws -> StagedMaterial
    func stage(imageData: Data) throws -> StagedMaterial
    func stage(url: URL) -> StagedMaterial
    func prepare(_ material: StagedMaterial) async -> PreparedText
    /// 删掉这次会话的 staging 目录。
    func discard()
}

/// 真实的 Intake：`MaterialIntake` 加上它的 staging 会话。
public struct FileQuickAddIntake: QuickAddIntaking {
    private let files: MaterialFiles
    private let session: StagingSession
    private let intake: MaterialIntake

    public init(files: MaterialFiles, fetcher: (any WebPageFetching)?) throws {
        self.files = files
        session = try files.makeStagingSession()
        intake = MaterialIntake(files: files, session: session, fetcher: fetcher)
    }

    public var sessionID: UUID { session.id }
    public func stage(fileAt source: URL) throws -> StagedMaterial { try intake.stage(fileAt: source) }
    public func stage(imageData: Data) throws -> StagedMaterial { try intake.stage(imageData: imageData) }
    public func stage(url: URL) -> StagedMaterial { intake.stage(url: url) }
    public func prepare(_ material: StagedMaterial) async -> PreparedText { await intake.prepare(material) }
    public func discard() { files.clear(session) }
}

/// 一次保存要写的内容。`entries[i].materialIndices` 是 `materials` 的 0 基下标。
public struct QuickAddSaveRequest: Sendable {
    public struct Entry: Sendable, Equatable {
        public var title: String
        public var due: DueDate?
        public var detail: String
        public var materialIndices: [Int]
        /// 是否挂一份 Source（原文）。
        public var includesSource: Bool
    }

    public var entries: [Entry]
    /// 用户输入的原文，Source 的内容。
    public var sourceText: String
    public var materials: [OrganizeMaterial]
    public var now: Date
}

/// 保存：写文件（每个 staging 文件只写一次）、组装 Note 和 Material 行、一个事务插入。返回新 Note 的 id，顺序和 `entries` 一致。
/// 真实实现等 `MaterialFiles` 共享存储的接口定稿后接上（ARCHITECTURE §3.3）。
public protocol QuickAddSaving: Sendable {
    func save(_ request: QuickAddSaveRequest) async throws -> [UUID]
}

/// 保存成功后让 Board 高亮新 Note（#8 的 `BoardController.highlight(noteIDs:)`）。
@MainActor
public protocol NoteHighlighting: AnyObject {
    func highlight(noteIDs: [UUID])
}
