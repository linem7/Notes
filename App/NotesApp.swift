import SwiftUI

@main
struct NotesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            StatusMenu(services: appDelegate.services)
        } label: {
            MenuBarLabel(services: appDelegate.services)
        }

        Settings {
            SettingsView(services: appDelegate.services)
        }
    }
}

/// 菜单栏图标的菜单（SPEC §1）：New Note、Show Board、Board Mode、Settings…、Quit Notes。
private struct StatusMenu: View {
    let services: AppServices
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button("New Note") { services.openQuickAdd() }
        Button("Show Board") { services.board.show() }
        Picker("Board Mode", selection: Bindable(services.board).mode) {
            Text("On Desktop").tag(BoardMode.onDesktop)
            Text("On Top").tag(BoardMode.onTop)
        }
        Divider()
        Button("Settings…") { AppWindow.openSettings(with: openSettings) }
            .keyboardShortcut(",")
        Divider()
        Button("Quit Notes") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}

/// 菜单栏图标和数字。顺便把打开设置的动作交给 services：Quick Add 在 NSHostingView 里，拿不到场景的环境值。
private struct MenuBarLabel: View {
    let services: AppServices
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        MenuBarIcon(count: services.badge.label)
            .onAppear {
                let openSettings = openSettings
                services.openSettings = { AppWindow.openSettings(with: openSettings) }
                // 首次启动自动打开设置的 Connection 页（SPEC §8）
                if services.firstLaunch.isFirstLaunch, !services.didOpenFirstLaunchSettings {
                    services.didOpenFirstLaunchSettings = true
                    services.openSettings()
                }
            }
    }
}

/// 打开设置窗口并带到最前面。
///
/// 从 macOS 14 开始 `NSApp.activate()` 是协作式的，不保证激活；从不激活 app 的 Quick Add 里打开窗口时，
/// 它可能出现在别的 app 后面。所以打开后再找到它，强制前置并设为 key。
@MainActor
enum AppWindow {
    static func openSettings(with openSettings: OpenSettingsAction) {
        // 先切成普通 app（出现在 Dock 和 ⌘Tab），再激活，见 RegularWindows
        RegularWindows.shared.windowDidOpen(.settings)
        NSApp.activate()
        openSettings()
        Task {
            // 窗口在 open 之后的下一轮才创建
            try? await Task.sleep(for: .milliseconds(100))
            let window = NSApp.windows.first { $0.identifier?.rawValue.contains("Settings") == true }
                ?? NSApp.orderedWindows.first { $0.isVisible && $0.canBecomeMain && !($0 is NSPanel) }
            window?.orderFrontRegardless()
            window?.makeKey()
        }
    }
}
