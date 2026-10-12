import AppKit
import NotesCore
import os

/// 组装应用：决定用哪个 `NoteStoring` 实现、数据目录在哪，并持有 Board。
/// 菜单栏、设置和 Quick Add（#9）通过 `services` 与它们交互。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var boardController: BoardController?
    let services = AppServices.make()
    private(set) var quickAddStore: QuickAddStore?
    private(set) var quickAddController: QuickAddController?
    private let logger = Logger(subsystem: "com.linem7.Notes", category: "App")
    private var maintenanceTimer: Timer?

    /// `~/Library/Application Support/com.linem7.Notes/`（SPEC §5）
    static var dataDirectory: URL {
        URL.applicationSupportDirectory.appendingPathComponent("com.linem7.Notes", isDirectory: true)
    }

    /// 正在使用的 Quick Add staging 会话；每 24 小时的清理要带上，免得删掉用户正在加的文件。
    /// 启动时接上 `QuickAddStore.currentStagingSessionID`（见 `applicationDidFinishLaunching`）。
    var currentStagingSessionID: () -> UUID? = { nil }

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let store = try NoteStore(directory: Self.dataDirectory)

            // 菜单栏与设置（#10）
            services.noteStore = store
            services.badge.start(store: store)
            let controller = BoardController(store: store, files: store.materialFiles, onAddNote: { [services] in
                services.openQuickAdd()
            })
            controller.start()
            boardController = controller
            services.board.attach(controller)

            // Quick Add（#9）：Connection、Default Model 和 key 的来源就是这里的 `AppServices`（设置页写
            // ConnectionStore 与 Keychain）；没有 Default Model 或 key 时 Organize 提示先添加 Connection，⌘⏎ 原样保存可用。
            let quickAddStore = QuickAddFactory.makeStore(
                files: store.materialFiles, noteStore: store, fetcher: WebPageFetcher(),
                organizer: ModelDraftOrganizer(configuration: { [services] in
                    Self.organizeConfiguration(from: services)
                })
            )
            quickAddStore.setHighlighter(controller)
            self.quickAddStore = quickAddStore
            let quickAddContext = QuickAddContext()
            // `AppServices.openSettings` 要等 `NotesApp` 的场景建立后才赋值，所以这里只转发、调用时现取，不拷贝当时的闭包
            quickAddContext.openSettings = { [services] in services.openSettings() }
            let quickAddController = QuickAddController(store: quickAddStore, context: quickAddContext)
            self.quickAddController = quickAddController
            // 菜单栏的 New Note（`NotesApp`）和 Board 顶栏的 + 都走这一条路：只打开，不是切换（切换归 Hotkey）。
            // 顶栏的「Connection / Model」是快照，唤起前现取一次，设置页刚改完 connection / model 也要跟着变。
            services.openQuickAdd = { [services] in
                quickAddContext.modelLabel = services.modelLabel
                quickAddController.show()
            }
            Hotkey.install { [services] in
                quickAddContext.modelLabel = services.modelLabel
                quickAddController.toggle()
            }
            Hotkey.warnIfTakenBySystem()

            currentStagingSessionID = { [weak quickAddStore] in quickAddStore?.currentStagingSessionID }
            startMaintenance(store: store)
        } catch {
            logger.error("Couldn't open the note store: \(error.localizedDescription, privacy: .public)")
            showStoreOpenFailure(error)
        }
        observeClock()
        if services.firstLaunch.isFirstLaunch { runFirstLaunch() }
    }

    // MARK: Organize 设置

    /// `ModelDraftOrganizer` 每次 Organize 现取设置：把 App 层的 `ResolvedOrganizeSettings`
    /// 给到 NotesCore 的 `OrganizeConfiguration`。
    ///
    /// 取设置在 main actor 上，而这个 `@Sendable` 闭包由 nonisolated 的 `ModelDraftOrganizer.organize`
    /// 调用，不保证在 main 上（NotesCore 没开 `NonisolatedNonsendingByDefault`），所以这里显式回主线程。
    private nonisolated static func organizeConfiguration(from services: AppServices) -> OrganizeConfiguration? {
        if Thread.isMainThread {
            return MainActor.assumeIsolated { mapOrganizeSettings(from: services) }
        }
        return DispatchQueue.main.sync { MainActor.assumeIsolated { mapOrganizeSettings(from: services) } }
    }

    /// 两个类型的字段一一对应，只有名字不同（`prompt` / `userPrompt`）。
    @MainActor
    private static func mapOrganizeSettings(from services: AppServices) -> OrganizeConfiguration? {
        services.resolvedOrganizeSettings(defaultPrompt: OrganizePrompt.default).map {
            OrganizeConfiguration(connection: $0.connection, modelID: $0.modelID, apiKey: $0.apiKey, userPrompt: $0.prompt)
        }
    }

    /// 打开不了数据库时没法继续：弹一次提示，只能退出。
    private func showStoreOpenFailure(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = String(localized: "Couldn't open the notes database")
        alert.informativeText = "\(error.localizedDescription)\n\n"
            + String(localized: "Data folder:") + " " + Self.dataDirectory.path
        alert.addButton(withTitle: String(localized: "Quit"))
        NSApp.activate()
        alert.runModal()
        NSApp.terminate(nil)
    }

    /// 首次启动（SPEC §8）：语言已在 `AppServices.make()` 里设为英文；这里开启 Launch at Login，
    /// 并让设置打开 Connection 页、预选 DeepSeek 模板（窗口本身由菜单栏 label 打开，见 `NotesApp`）。
    /// Board（On Desktop）默认显示。Hotkey 的注册和冲突检测在启动时已经做完（`Hotkey.install`、`Hotkey.warnIfTakenBySystem`）。
    private func runFirstLaunch() {
        services.launchAtLogin.setEnabled(true)
        services.navigation.showConnections(template: .deepSeek)
    }

    // MARK: 清理

    /// 启动时跑一次（`.startup`，此时没有 Quick Add 会话），之后每 24 小时一次（`.periodic`，要带当前会话）。两个调用点见 `MaintenanceCalls`。
    private func startMaintenance(store: NoteStore) {
        let calls = MaintenanceCalls(runner: NotesMaintenanceRunner(NotesMaintenance(store: store, files: store.materialFiles)))
        let logger = logger
        Task { Self.log(await calls.runAtLaunch(), to: logger) }
        maintenanceTimer = Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let session = self.currentStagingSessionID()
                Task { Self.log(await calls.runPeriodically(currentStagingSession: session), to: logger) }
            }
        }
    }

    private nonisolated static func log(_ report: MaintenanceReport, to logger: Logger) {
        if !report.failedSteps.isEmpty {
            logger.error("Maintenance failed steps: \(report.failedSteps.joined(separator: ","), privacy: .public)")
        }
    }

    /// 跨过午夜、系统唤醒、时区或日期改变时，菜单栏数字要重新判断「今天」。
    private func observeClock() {
        let badge = services.badge
        let refresh: @Sendable (Notification) -> Void = { _ in
            MainActor.assumeIsolated { badge.refresh() }
        }
        NotificationCenter.default.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main, using: refresh)
        NotificationCenter.default.addObserver(forName: NSNotification.Name.NSSystemTimeZoneDidChange, object: nil, queue: .main, using: refresh)
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main, using: refresh)
    }
}
