import AppKit
import SwiftUI

/// Board 的窗口：半透明、大圆角、可拖动可调大小的面板（ARCHITECTURE §7，ADR-0001）。
/// 和 Quick Add 不同，它要能点击和编辑文字，所以不是 `.nonactivatingPanel`。
final class BoardWindow: NSPanel {
    static let cornerRadius: CGFloat = 22
    static let frameAutosaveName = "Board"
    static let defaultSize = NSSize(width: 340, height: 560)

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init<Content: View>(mode: BoardMode, rootView: Content) {
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            styleMask: [.borderless, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isMovable = true
        // 只有顶栏能拖（performDrag），背景拖动会和列表、选中文字冲突
        isMovableByWindowBackground = false
        minSize = NSSize(width: 280, height: 240)
        animationBehavior = .none

        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.maskImage = Self.roundedRectMask(cornerRadius: Self.cornerRadius)

        let hosting = NSHostingView(rootView: rootView)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: background.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        contentView = background

        apply(mode: mode)
        restoreFrame()
    }

    func apply(mode: BoardMode) {
        level = mode.level
        collectionBehavior = mode.collectionBehavior
    }

    /// 有保存过的位置和大小就恢复；首次出现在主屏幕右侧。之后的改动由 AppKit 自动保存。
    private func restoreFrame() {
        let key = "NSWindow Frame \(Self.frameAutosaveName)"
        let hasSavedFrame = UserDefaults.standard.string(forKey: key) != nil
        if !hasSavedFrame, let screen = NSScreen.main ?? NSScreen.screens.first {
            let visible = screen.visibleFrame
            let size = Self.defaultSize
            let height = min(size.height, visible.height - 48)
            setFrame(
                NSRect(x: visible.maxX - size.width - 24, y: visible.maxY - height - 24, width: size.width, height: height),
                display: false
            )
        }
        setFrameAutosaveName(Self.frameAutosaveName)
    }

    /// 面板不一定在 key app 里，编辑命令（⌘C / ⌘V / ⌘Z……）没有主菜单可走，在这里直接发给响应链。
    /// 做法同 Chatbot 的 QuickPanel。
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if super.performKeyEquivalent(with: event) { return true }
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let action: Selector? = switch (modifiers, event.charactersIgnoringModifiers) {
        case (.command, "x"): #selector(NSText.cut(_:))
        case (.command, "c"): #selector(NSText.copy(_:))
        case (.command, "v"): #selector(NSText.paste(_:))
        case (.command, "a"): #selector(NSText.selectAll(_:))
        case (.command, "z"): Selector(("undo:"))
        case ([.command, .shift], "z"), ([.command, .shift], "Z"): Selector(("redo:"))
        default: nil
        }
        guard let action else { return false }
        return NSApp.sendAction(action, to: nil, from: self)
    }

    private static func roundedRectMask(cornerRadius: CGFloat) -> NSImage {
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

/// 顶栏的拖动区：按下后交给窗口的 `performDrag`，同 Chatbot 的做法。
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { false }
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }
}
