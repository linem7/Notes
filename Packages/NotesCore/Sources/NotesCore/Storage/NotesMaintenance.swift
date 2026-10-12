import Foundation

public struct MaintenanceReport: Equatable, Sendable {
    public var expiredNotesDeleted = 0
    public var garbageFilesDeleted = 0
    public var stagingDirectoriesDeleted = 0
    /// 哪一步失败了（只记步骤名，不含 Note 内容）。
    public var failedSteps: [String] = []
}

/// 清理（ARCHITECTURE §9）：完成超过 30 天的 Note、没人引用的 Material 文件、遗留的 staging。
/// App 在启动时和之后每 24 小时调用 `run`。
public struct NotesMaintenance: Sendable {
    private let store: any NoteStoring
    private let files: MaterialFiles

    public init(store: any NoteStoring, files: MaterialFiles) {
        self.store = store
        self.files = files
    }

    /// 不抛错：某一步失败记在 report 里，其余步骤照常。
    /// - Parameters:
    ///   - keepingStaging: 正在使用的 Quick Add 会话，每 24 小时那次要带上，不然会把用户正在加的文件删掉。
    ///   - respectingStagingGracePeriod: 每 24 小时那次传 true：修改时间在 10 分钟之内的 staging 条目不删，
    ///     因为读到 `keepingStaging` 之后用户可能又粘贴了文件、Quick Add 新建了会话。启动时传 false（默认），
    ///     这时没有活跃的会话，staging 全部清掉。
    public func run(
        now: Date = Date(), keepingStaging: Set<UUID> = [], respectingStagingGracePeriod: Bool = false
    ) async -> MaintenanceReport {
        var report = MaintenanceReport()

        do {
            report.expiredNotesDeleted = try await store.deleteExpiredDone(now: now)
        } catch {
            report.failedSteps.append("deleteExpiredDone")
        }

        do {
            let garbage = files.collectGarbage(referenced: try await store.referencedFileNames(), now: now)
            report.garbageFilesDeleted = garbage.removed
            if garbage.failed > 0 { report.failedSteps.append("garbageCollection") }
        } catch {
            report.failedSteps.append("garbageCollection")
        }

        let staging = files.clearStaging(keeping: keepingStaging, respectingGracePeriod: respectingStagingGracePeriod, now: now)
        report.stagingDirectoriesDeleted = staging.removed
        if staging.failed > 0 { report.failedSteps.append("staging") }
        return report
    }
}
