import Foundation

public struct MaintenanceReport: Equatable, Sendable {
    public var expiredNotesDeleted = 0
    public var garbageFilesDeleted = 0
    public var stagingDirectoriesDeleted = 0
    /// 哪一步失败了（只记步骤名，不含 Note 内容）。
    public var failedSteps: [String] = []
}

/// 清理的时机。没有默认值：忘了选就编译不过，不会悄悄走错的那条路。
public enum MaintenanceMode: Sendable, Equatable {
    /// App 启动时：没有活跃的会话，staging 全部清掉。
    case startup
    /// 每 24 小时：带上正在使用的 Quick Add 会话；10 分钟内改过的 staging 条目也留着。
    case periodic(keepingStaging: Set<UUID>)
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

    /// 不抛错：某一步失败记在 report 里，其余步骤照常。`mode` 没有默认值，调用方必须选：
    /// - `.startup`：启动时。没有活跃的 Quick Add 会话，staging 全部清掉（不看宽限期）。
    /// - `.periodic(keepingStaging:)`：每 24 小时。跳过 `keepingStaging` 里正在使用的会话，并且
    ///   修改时间在 10 分钟之内的 staging 条目也不删（读到会话 ID 之后用户可能又粘贴了文件、新建了会话）。
    ///
    /// 两种模式回收文件（`collectGarbage`）都带 10 分钟宽限期。
    public func run(_ mode: MaintenanceMode, now: Date = Date()) async -> MaintenanceReport {
        var report = MaintenanceReport()

        do {
            report.expiredNotesDeleted = try await store.deleteExpiredDone(now: now)
        } catch {
            report.failedSteps.append("deleteExpiredDone")
        }

        do {
            let garbage = files.collectGarbage(referenced: try await store.referencedFileNames(), now: now)
            report.garbageFilesDeleted = garbage.removed
            // 删不掉和列不出来都算这一步失败（#36）：列不出来时 removed/failed 都是 0，光看它们分不出「没有垃圾」。
            if garbage.failed > 0 || garbage.listingFailed { report.failedSteps.append("garbageCollection") }
        } catch {
            report.failedSteps.append("garbageCollection")
        }

        let staging: (removed: Int, failed: Int, listingFailed: Bool)
        switch mode {
        case .startup:
            staging = files.clearStaging(keeping: [], respectingGracePeriod: false, now: now)
        case .periodic(let keeping):
            staging = files.clearStaging(keeping: keeping, respectingGracePeriod: true, now: now)
        }
        report.stagingDirectoriesDeleted = staging.removed
        if staging.failed > 0 || staging.listingFailed { report.failedSteps.append("staging") }
        return report
    }
}
