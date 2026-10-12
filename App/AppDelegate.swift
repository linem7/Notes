import AppKit
import NotesCore
import os

/// 组装应用：决定用哪个 `NoteStoring` 实现、数据目录在哪，并持有 Board。
/// 菜单栏（#10）和 Quick Add（#9）通过 `boardController` 与 Board 交互。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var boardController: BoardController?
    private(set) var quickAddStore: QuickAddStore?
    private(set) var quickAddController: QuickAddController?
    private let logger = Logger(subsystem: "com.linem7.Notes", category: "App")

    /// `~/Library/Application Support/com.linem7.Notes/`（SPEC §5）
    static var dataDirectory: URL {
        URL.applicationSupportDirectory.appendingPathComponent("com.linem7.Notes", isDirectory: true)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let store = try NoteStore(directory: Self.dataDirectory)
            let controller = BoardController(store: store, files: store.materialFiles, onAddNote: { [weak self] in
                // Board 顶栏的 + 只负责打开，不是切换
                self?.quickAddController?.show()
            })
            controller.start()
            boardController = controller

            // Connection、Default Model 和 key 的来源在 #10；接上之前 Organize 一律提示先添加 Connection，⌘⏎ 原样保存可用
            let quickAddStore = QuickAddFactory.makeStore(
                files: store.materialFiles, noteStore: store, fetcher: WebPageFetcher(),
                organizer: ModelDraftOrganizer(configuration: { nil })
            )
            quickAddStore.setHighlighter(controller)
            self.quickAddStore = quickAddStore
            let quickAddController = QuickAddController(store: quickAddStore)
            self.quickAddController = quickAddController
            Hotkey.install { quickAddController.toggle() }
            Hotkey.warnIfTakenBySystem()
        } catch {
            logger.error("Couldn't open the note store: \(error.localizedDescription, privacy: .public)")
            showStoreOpenFailure(error)
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
}
