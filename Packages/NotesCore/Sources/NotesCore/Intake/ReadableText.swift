import Foundation

/// Readable Text 为什么拿不到。文案在 App 里按 case 映射（悬停说明），这里不放界面字符串。
public enum UnavailableReason: Hashable, Sendable {
    /// Word、Excel、压缩包、bundle 目录……只存不读（SPEC §3.2）。
    case notReadable
    /// 文件读不出来（权限、已被移走、PDF 损坏）。
    case unreadableFile
    /// PDF 有密码。
    case passwordProtected
    /// OCR 跑完了但没有识别出文字（图片、扫描版 PDF）。
    case noTextRecognized
    /// 网页没抓到（超时、加载失败）。
    case pageLoadFailed
    /// 网页抓到了但没有正文。
    case pageHasNoText
    /// 被取消了（Material 被移除，或面板清空）。
    case cancelled
}

public enum ReadableTextState: Hashable, Sendable {
    case pending
    case ready(String)
    case unavailable(UnavailableReason)
}

/// `MaterialIntake.prepare` 的结果。`title` 和 `snapshotPDF` 只有 Web Page 会有。
public struct PreparedText: Hashable, Sendable {
    public var state: ReadableTextState
    public var title: String?
    public var snapshotPDF: Data?

    public init(state: ReadableTextState, title: String? = nil, snapshotPDF: Data? = nil) {
        self.state = state
        self.title = title
        self.snapshotPDF = snapshotPDF
    }
}

/// 网页抓取的结果（ARCHITECTURE §6）。
public struct WebPageResult: Hashable, Sendable {
    public var title: String
    public var text: String
    public var pdfData: Data?

    public init(title: String, text: String, pdfData: Data? = nil) {
        self.title = title
        self.text = text
        self.pdfData = pdfData
    }
}

/// App 在 #7 里用离屏 WKWebView 实现；NotesCore 只依赖这个协议。
/// 抓不到时抛错（超时、加载失败），Intake 会映射成 `.pageLoadFailed`。
public protocol WebPageFetching: Sendable {
    func fetch(_ url: URL) async throws -> WebPageResult
}
