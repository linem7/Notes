import AppKit

/// Board 的窗口层级（CONTEXT.md 的 Board Mode，ARCHITECTURE §7）。
enum BoardMode: String, CaseIterable {
    case onDesktop
    case onTop

    /// On Desktop：在桌面图标之上、普通窗口之下；On Top：始终在普通窗口上方。
    var level: NSWindow.Level {
        switch self {
        case .onDesktop: NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        case .onTop: .floating
        }
    }

    /// On Desktop 带 `.stationary`，「显示桌面」时不被推开。
    var collectionBehavior: NSWindow.CollectionBehavior {
        switch self {
        case .onDesktop: [.canJoinAllSpaces, .stationary, .ignoresCycle]
        case .onTop: [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        }
    }
}
