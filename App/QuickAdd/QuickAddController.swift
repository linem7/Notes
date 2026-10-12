import AppKit
import Carbon.HIToolbox
import NotesCore
import Observation
import SwiftUI

/// 面板顶栏要显示、以及错误里「打开设置」要用的东西，由 App 生命周期（#10）填。
@MainActor
@Observable
final class QuickAddContext {
    /// 「Connection / Model」，没有 Connection 时为 nil。
    var modelLabel: String?
    var openSettings: () -> Void = {}
}

/// 持有 Quick Add 面板：配置窗口、显示和隐藏、处理面板里的快捷键（ARCHITECTURE §8，SPEC §3.1、§3.4）。
///
/// 隐藏只是 `orderOut`，不碰 `QuickAddStore`：有 Draft 或正在 Organize 时，再唤起保持原状。
@MainActor
final class QuickAddController: NSObject, NSWindowDelegate {
    private static let width: CGFloat = 640
    private static let preferredHeight: CGFloat = 560
    private static let maxScreenHeightFraction: CGFloat = 0.7
    /// 面板顶边距屏幕顶边的比例，对应「偏上居中」。
    private static let topOffsetFraction: CGFloat = 0.16
    private static let cornerRadius: CGFloat = 22

    let store: QuickAddStore
    let context: QuickAddContext
    private let composer = ComposerHandle()
    private let panel: QuickAddPanel
    private var isShown = false
    private var keyMonitor: Any?
    /// 文件面板打开期间，面板会失焦，但不应该隐藏。
    private var isPresentingFilePicker = false
    /// 为了打开文件面板激活过 app 时，原来在前台的 app。隐藏时把激活状态还给它（面板不抢前台 app 的激活状态）。
    private var previousFrontmostApp: NSRunningApplication?

    init(store: QuickAddStore, context: QuickAddContext = QuickAddContext()) {
        self.store = store
        self.context = context
        panel = QuickAddPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.preferredHeight),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        super.init()

        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        // 只有顶栏能拖：isMovable 给 performDrag 用；isMovableByWindowBackground 保持 false，
        // 否则在文字区按住想选字会变成拖窗口
        panel.isMovable = true
        panel.isMovableByWindowBackground = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.delegate = self
        panel.contentView = makeContentView()
        store.onDidSave = { [weak self] in self?.hide() }
    }

    func toggle() {
        if isShown { hide() } else { show() }
    }

    func show() {
        guard !isShown else { return }
        // app 被隐藏（hidden）时，不激活 app 的面板也显示不出来；只取消隐藏，不激活
        if NSApp.isHidden { NSApp.unhideWithoutActivation() }
        isShown = true
        // 位置不持久化：每次唤起都在鼠标所在屏幕偏上居中
        positionOnMouseScreen()
        panel.makeKeyAndOrderFront(nil)
        panel.contentView?.layoutSubtreeIfNeeded()
        composer.focus()
        installKeyMonitor()
    }

    /// 再按一次 Hotkey、按 Esc、失焦、保存成功时调用。只隐藏，不动 store。
    func hide() {
        guard isShown else { return }
        isShown = false
        removeKeyMonitor()
        panel.orderOut(nil)
        restorePreviousFrontmostApp()
    }

    /// 把激活状态还给打开文件面板之前在前台的 app。设置窗口开着时，说明用户正在用我们的 app，不还。
    private func restorePreviousFrontmostApp() {
        guard let app = previousFrontmostApp else { return }
        previousFrontmostApp = nil
        // 用户已经自己切到别的 app 了，就不要再把焦点抢回去
        guard NSApp.isActive else { return }
        let hasOtherVisibleWindow = NSApp.windows.contains { $0 !== panel && $0.isVisible && $0.canBecomeMain }
        guard !hasOtherVisibleWindow, !app.isTerminated else { return }
        // macOS 14 起的协作式激活：先让出，再请它激活（#10 的 RegularWindows 也会有同样的扩展，这里内联避免重名）
        NSApp.yieldActivation(to: app)
        _ = app.activate(from: .current, options: [])
    }

    func windowDidResignKey(_ notification: Notification) {
        guard !isPresentingFilePicker else { return }
        hide()
    }

    // MARK: - 「+」选文件

    /// 打开文件面板选 File（SPEC §3.2）。
    ///
    /// 面板不激活 app，app 本身不在前台，文件面板可能出现在别的 app 的窗口后面。
    /// 所以打开前先激活 app 兜底；关闭后让面板重新成为 key window，焦点回到输入框。
    /// 激活过的话，隐藏面板时再把激活状态还给原来的 app（见 `restorePreviousFrontmostApp`）。
    private func presentFilePicker() {
        guard isShown, !isPresentingFilePicker else { return }
        isPresentingFilePicker = true
        defer {
            isPresentingFilePicker = false
            panel.makeKeyAndOrderFront(nil)
            composer.focus()
        }
        if previousFrontmostApp == nil, let frontmost = NSWorkspace.shared.frontmostApplication, frontmost != .current {
            previousFrontmostApp = frontmost
        }
        NSApp.activate()
        let openPanel = NSOpenPanel()
        openPanel.allowsMultipleSelection = true
        openPanel.canChooseDirectories = false
        openPanel.canChooseFiles = true
        guard openPanel.runModal() == .OK else { return }
        store.addFiles(openPanel.urls)
    }

    // MARK: - 布局

    private func makeContentView() -> NSView {
        let frame = NSRect(x: 0, y: 0, width: Self.width, height: Self.preferredHeight)
        let background = NSVisualEffectView(frame: frame)
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.maskImage = .roundedRectMask(cornerRadius: Self.cornerRadius)

        let view = QuickAddView(
            store: store,
            context: context,
            composer: composer,
            onPickFiles: { [weak self] in self?.presentFilePicker() }
        )
        let hosting = NSHostingView(rootView: view)
        hosting.sizingOptions = []
        hosting.frame = background.bounds
        hosting.autoresizingMask = [.width, .height]
        background.addSubview(hosting)
        return background
    }

    /// 出现在鼠标所在屏幕的偏上居中位置。高度固定约 560pt，最多占可见区域的 70%。
    private func positionOnMouseScreen() {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main else {
            return
        }
        let visible = screen.visibleFrame
        let width = min(Self.width, visible.width - 32)
        let height = min(Self.preferredHeight, visible.height * Self.maxScreenHeightFraction)
        let top = min(screen.frame.maxY - screen.frame.height * Self.topOffsetFraction, visible.maxY)
        let originY = max(visible.minY, top - height)
        panel.setFrame(NSRect(x: visible.midX - width / 2, y: originY, width: width, height: height), display: false)
    }

    // MARK: - 快捷键（SPEC §3.4）

    /// AppKit 把 Esc 和 ⌘. 都当作 `cancelOperation:`，所以不用 `.onExitCommand`，而是在这里按 keyCode 区分。
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, MainActor.assumeIsolated({ self.handleKeyDown(event) }) else { return event }
            return nil
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        guard event.window === panel else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let hasMarkedText = (panel.firstResponder as? NSTextView)?.hasMarkedText() == true

        if event.keyCode == UInt16(kVK_Escape), modifiers.isEmpty {
            // 输入法正在组字时，Esc 交给输入法取消组字。
            if hasMarkedText { return false }
            // Organize 进行中先取消，面板不动；否则隐藏面板
            if !store.handleEscape() { hide() }
            return true
        }

        guard modifiers == .command else { return false }
        if event.keyCode == UInt16(kVK_Return) || event.keyCode == UInt16(kVK_ANSI_KeypadEnter) {
            if hasMarkedText { return false }
            Task { await store.save() }
            return true
        }
        if event.charactersIgnoringModifiers == "." {
            store.cancelOrganize()
            return true
        }
        return false
    }
}

private extension NSImage {
    /// `NSVisualEffectView.maskImage` 用的圆角矩形，可以拉伸到任意尺寸。
    static func roundedRectMask(cornerRadius: CGFloat) -> NSImage {
        let edge = cornerRadius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: cornerRadius, left: cornerRadius, bottom: cornerRadius, right: cornerRadius)
        image.resizingMode = .stretch
        return image
    }
}
