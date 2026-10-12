import AppKit

/// 打开文件或网址。包一层是为了让 Material 的打开逻辑可以换成测试替身。
@MainActor
protocol URLOpening {
    func open(_ url: URL)
}

struct WorkspaceURLOpener: URLOpening {
    func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}
