import AppKit
import NotesCore
import SwiftUI

/// 持有 Board 窗口和模型：Board Mode、显示/隐藏（都持久化）、午夜重分组、新 Note 高亮。
/// 菜单栏（#10）调用 `show()` / `mode`；Quick Add（#9）保存后调用 `highlight(noteIDs:)`。
@MainActor
final class BoardController {
    private static let modeKey = "boardMode"
    private static let visibleKey = "boardVisible"

    let model: BoardModel
    private let defaults: UserDefaults
    private let onAddNote: () -> Void
    private var window: BoardWindow?

    var mode: BoardMode {
        didSet {
            defaults.set(mode.rawValue, forKey: Self.modeKey)
            window?.apply(mode: mode)
        }
    }

    var isVisible: Bool { window?.isVisible ?? false }

    init(
        store: any NoteStoring, files: MaterialFiles, defaults: UserDefaults = .standard,
        onAddNote: @escaping () -> Void
    ) {
        self.defaults = defaults
        self.onAddNote = onAddNote
        mode = defaults.string(forKey: Self.modeKey).flatMap(BoardMode.init(rawValue:)) ?? .onDesktop
        model = BoardModel(store: store, files: files)
        observeClock()
    }

    /// app 启动时调用：开始订阅，并按上次的显示状态恢复（第一次默认显示）。
    func start() {
        model.start()
        if defaults.object(forKey: Self.visibleKey) as? Bool ?? true { show() }
    }

    func show() {
        let window = ensureWindow()
        // 只把 Board 摆到前面，不激活 app：On Desktop 下不要把别的 app 的窗口压下去
        window.orderFrontRegardless()
        defaults.set(true, forKey: Self.visibleKey)
    }

    func hide() {
        window?.orderOut(nil)
        defaults.set(false, forKey: Self.visibleKey)
    }

    /// 新 Note 保存后调用：短暂高亮并滚动到第一条；Board 被隐藏时先显示出来。
    func highlight(noteIDs: [UUID]) {
        show()
        model.highlight(noteIDs: noteIDs)
    }

    private func ensureWindow() -> BoardWindow {
        if let window { return window }
        let view = BoardView(
            model: model, opener: WorkspaceURLOpener(),
            onAddNote: { [weak self] in self?.onAddNote() },
            onClose: { [weak self] in self?.hide() }
        )
        let window = BoardWindow(mode: mode, rootView: view)
        self.window = window
        // 切到别的 app（Board 不再是 key window）时，保存正在编辑的
        NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.commitEditing() }
        }
        return window
    }

    /// 跨过午夜、系统唤醒、时区或日期改变时重新判断「今天」。
    private func observeClock() {
        let refresh: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.model.refreshToday() }
        }
        NotificationCenter.default.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main, using: refresh)
        NotificationCenter.default.addObserver(forName: NSNotification.Name.NSSystemTimeZoneDidChange, object: nil, queue: .main, using: refresh)
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main, using: refresh)
    }
}
