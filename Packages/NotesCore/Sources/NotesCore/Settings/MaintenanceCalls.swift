import Foundation

/// 清理的执行方。真实实现是 `NotesMaintenance`（见 `NotesMaintenanceRunner`），测试用 spy。
public protocol MaintenanceRunning: Sendable {
    func run(_ mode: MaintenanceMode) async -> MaintenanceReport
}

/// `NotesMaintenance` 的两个调用点集中在这里（ARCHITECTURE §9）：
/// 启动那次是 `.startup`（全清 staging）；每 24 小时那次是 `.periodic(keepingStaging:)`，保留当前 Quick Add 会话。
public struct MaintenanceCalls: Sendable {
    private let runner: any MaintenanceRunning

    public init(runner: any MaintenanceRunning) {
        self.runner = runner
    }

    public func runAtLaunch() async -> MaintenanceReport {
        await runner.run(.startup)
    }

    /// `currentStagingSession` 是 `QuickAddStore.currentStagingSessionID`，没有会话时为 nil。
    public func runPeriodically(currentStagingSession: UUID?) async -> MaintenanceReport {
        await runner.run(.periodic(keepingStaging: currentStagingSession.map { [$0] } ?? []))
    }
}

public struct NotesMaintenanceRunner: MaintenanceRunning {
    private let maintenance: NotesMaintenance

    public init(_ maintenance: NotesMaintenance) {
        self.maintenance = maintenance
    }

    public func run(_ mode: MaintenanceMode) async -> MaintenanceReport {
        await maintenance.run(mode)
    }
}
