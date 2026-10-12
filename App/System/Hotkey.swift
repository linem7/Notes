import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// 唤起 Quick Add 的 Hotkey，默认 option+N（SPEC §3.1）。
    /// 设置页（#10）放录制控件；注册、冲突检测由 Quick Add（#9）加到这个文件里。
    static let quickAdd = Self("quickAdd", initial: .init(.n, modifiers: [.option]))
}
