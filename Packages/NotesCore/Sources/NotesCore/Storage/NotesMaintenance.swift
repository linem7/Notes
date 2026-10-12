import Foundation

public struct MaintenanceReport: Equatable, Sendable {
    public var expiredNotesDeleted = 0
    public var orphanDirectoriesDeleted = 0
    public var stagingDirectoriesDeleted = 0
    /// 哪一步失败了（只记步骤名，不含 Note 内容）。
    public var failedSteps: [String] = []
}

/// 清理（ARCHITECTURE §9）：完成超过 30 天的 Note、没有记录的 Material 目录、遗留的 staging。
/// App 在启动时和之后每 24 小时调用 `run`。
public struct NotesMaintenance: Sendable {
    /// 刚改过的目录不当孤儿：Quick Add 保存时先写文件再插入记录，这中间不能被清掉。
    static let orphanGracePeriod: TimeInterval = 600

    private let store: any NoteStoring
    private let files: MaterialFiles

    public init(store: any NoteStoring, files: MaterialFiles) {
        self.store = store
        self.files = files
    }

    /// 不抛错：某一步失败记在 report 里，其余步骤照常。
    /// `keepingStaging` 是正在使用的 Quick Add 会话，每 24 小时那次要带上，不然会把用户正在加的文件删掉。
    public func run(now: Date = Date(), keepingStaging: Set<UUID> = []) async -> MaintenanceReport {
        var report = MaintenanceReport()

        do {
            report.expiredNotesDeleted = try await store.deleteExpiredDone(now: now)
        } catch {
            report.failedSteps.append("deleteExpiredDone")
        }

        do {
            let known = Set(try await store.allNotes().map(\.id))
            for (id, modified) in files.noteDirectories() where !known.contains(id) {
                guard now.timeIntervalSince(modified) > Self.orphanGracePeriod else { continue }
                files.removeNoteDirectory(id)
                report.orphanDirectoriesDeleted += 1
            }
        } catch {
            report.failedSteps.append("orphanDirectories")
        }

        report.stagingDirectoriesDeleted = files.clearStaging(keeping: keepingStaging)
        return report
    }
}
