import AppKit
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// 唤起 Quick Add 的 Hotkey，默认 option+N（SPEC §3.1）。
    static let quickAdd = Self("quickAdd", initial: .init(.n, modifiers: [.option]))
}

/// Hotkey 的注册和冲突检测（SPEC §3.1，移植 Chatbot 的 `Hotkey`，去掉 ⌘ 双击）。
///
/// 只能检测和系统快捷键的冲突。其他 app 用 Carbon 注册的同一组合检测不到，
/// 所以在设置里 Hotkey 旁边放静态提示（`otherAppsHint`）。录制控件归设置页（#10）。
enum Hotkey {
    static let otherAppsHint: LocalizedStringResource =
        "If nothing happens when you press the Hotkey, it may conflict with another app. Try a different combination."

    private static let lastWarnedKey = "hotkeyConflictWarnedShortcut"

    /// app 启动时调一次：按 Hotkey 就调 `onToggle`。
    @MainActor
    static func install(onToggle: @escaping @MainActor () -> Void) {
        KeyboardShortcuts.onKeyDown(for: .quickAdd) {
            Task { @MainActor in onToggle() }
        }
    }

    /// 当前 Hotkey 和一个已启用的系统快捷键相同时弹窗提示。同一个组合只提示一次。首次启动和改键时调用。
    @MainActor
    static func warnIfTakenBySystem() {
        guard let shortcut = KeyboardShortcuts.getShortcut(for: .quickAdd) else { return }
        let defaults = UserDefaults.standard
        guard shortcut.isTakenBySystem else {
            defaults.removeObject(forKey: lastWarnedKey)
            return
        }
        guard defaults.string(forKey: lastWarnedKey) != shortcut.description else { return }
        defaults.set(shortcut.description, forKey: lastWarnedKey)

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Hotkey \(shortcut.description) is used by macOS")
        alert.informativeText = String(localized: "Pressing it won't open Quick Add. Turn off that shortcut in System Settings › Keyboard › Keyboard Shortcuts, or choose another Hotkey in Notes' settings.")
        NSApp.activate()
        alert.runModal()
    }
}
