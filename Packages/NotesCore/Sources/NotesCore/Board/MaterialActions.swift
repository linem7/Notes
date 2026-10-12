import Foundation

/// 一个 Material 在 Board 上能做什么（SPEC §2.3）。纯数据，App 层据此画按钮、调用 NSWorkspace。
public struct MaterialActions: Equatable, Sendable {
    /// 点击条目本身打开的东西：File 的副本；Web Page 的原始 URL。Source 没有。
    public var primary: URL?
    /// Web Page 的 PDF 快照；快照不存在时为 nil（不显示按钮）。
    public var snapshot: URL?
    /// 可以在行内展开的文字：Source 的原文、Web Page 抽出的正文。文件不存在时为 nil。
    public var inlineText: MaterialFileRole?
    /// 点击条目是展开而不是打开（Source）。
    public var primaryTogglesInlineText: Bool

    public init(material: Material, files: any MaterialFileResolving) {
        switch material.kind {
        case .file:
            primary = files.url(for: material, role: .stored)
            snapshot = nil
            inlineText = nil
            primaryTogglesInlineText = false
        case .webPage:
            primary = Self.webURL(material.url)
            snapshot = files.url(for: material, role: .snapshot)
            inlineText = files.url(for: material, role: .text) == nil ? nil : .text
            primaryTogglesInlineText = false
        case .source:
            primary = nil
            snapshot = nil
            inlineText = files.url(for: material, role: .stored) == nil ? nil : .stored
            primaryTogglesInlineText = true
        }
    }

    /// 只放行 http / https。
    private static func webURL(_ string: String?) -> URL? {
        guard let string, let url = URL(string: string),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https"
        else { return nil }
        return url
    }
}
