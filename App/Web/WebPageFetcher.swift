import Foundation
import NotesCore
import WebKit

/// 离屏 WKWebView 抓网页（ARCHITECTURE §6，ADR-0002）：不带用户的 cookie，等页面渲染后用
/// Readability.js 抽正文，再拍一份 PDF 快照。排队、限流、超时和取消的规则在 NotesCore 的 `FetchRunner` 里
/// （有单元测试），选正文的规则在 `WebPageExtraction`，这里只负责 WebKit。
final class WebPageFetcher: WebPageFetching {
    private let runner = FetchRunner()

    init() {}

    func fetch(_ url: URL) async throws -> WebPageResult {
        guard WebFetchPolicy.isFetchable(url) else { throw WebFetchError.invalidURL }
        return try await runner.run { try await PageLoader.load(url) }
    }
}

/// 一次抓取用一个 WKWebView，用完就丢。WebKit 只能在主线程用。
@MainActor
private final class PageLoader: NSObject, WKNavigationDelegate {
    /// Readability.js 的内容，只读一次。
    private static let readabilitySource: String? = Bundle.main.url(forResource: "Readability", withExtension: "js")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }

    private let webView: WKWebView
    private var navigation: CheckedContinuation<Void, any Error>?
    private var isTornDown = false

    private override init() {
        let configuration = WKWebViewConfiguration()
        // 非持久的 data store：不读也不写用户的 cookie 和缓存
        configuration.websiteDataStore = .nonPersistent()
        // 默认的 User-Agent 没有 Safari 标识，有些网站会给降级页或验证页
        configuration.applicationNameForUserAgent = "Version/26.0 Safari/605.1.15"
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1_024, height: 768), configuration: configuration)
        super.init()
        webView.navigationDelegate = self
    }

    /// 任务被取消（调用方取消，或 `FetchRunner` 超时）时 `teardown`：停止加载并跳到空白页，
    /// 页面里不响应取消的脚本和 `pdf()` 随之结束，WKWebView 也就能释放。
    static func load(_ url: URL) async throws -> WebPageResult {
        let loader = PageLoader()
        return try await withTaskCancellationHandler {
            try await loader.run(url)
        } onCancel: {
            Task { @MainActor in loader.teardown() }
        }
    }

    private func run(_ url: URL) async throws -> WebPageResult {
        defer { teardown() }
        if isTornDown { throw CancellationError() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            navigation = continuation
            webView.load(URLRequest(url: url))
        }

        // didFinish 之后再等一会儿，给靠 JavaScript 渲染的页面时间
        try await Task.sleep(for: WebFetchPolicy.settleDelay)

        let output = try await extract()
        // 没有正文时 text 为 ""，由 MaterialIntake 映射成 pageHasNoText；快照照样要
        let chosen = WebPageExtraction.choose(output, url: url)
        // 快照有自己的短时限，失败或超时不影响正文
        let pdf = try? await withFetchTimeout(WebFetchPolicy.snapshotTimeout) { [self] in try await self.makePDF() }
        return WebPageResult(title: chosen.title, text: chosen.text, pdfData: pdf)
    }

    private func makePDF() async throws -> Data {
        try await webView.pdf(configuration: WKPDFConfiguration())
    }

    /// 在 App 自己的 content world 里跑 Readability，页面脚本碰不到它；失败时 article 是 null。
    private func extract() async throws -> WebPageScriptOutput {
        guard let readability = Self.readabilitySource else { throw WebFetchError.loadFailed }

        let body = """
            \(readability)
            var article = null;
            try {
                var parsed = new Readability(document.cloneNode(true)).parse();
                if (parsed) { article = { title: parsed.title || "", text: parsed.textContent || "" }; }
            } catch (e) {}
            return JSON.stringify({
                article: article,
                pageTitle: document.title || "",
                innerText: document.body ? document.body.innerText : ""
            });
            """
        let result = try await webView.callAsyncJavaScript(body, arguments: [:], in: nil, contentWorld: .defaultClient)
        guard let json = result as? String else { throw WebFetchError.loadFailed }
        return try WebPageScriptOutput(json: json)
    }

    private func teardown() {
        guard !isTornDown else { return }
        isTornDown = true
        finishNavigation(.failure(CancellationError()))
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.load(URLRequest(url: URL(string: "about:blank")!))
    }

    private func finishNavigation(_ result: Result<Void, any Error>) {
        guard let continuation = navigation else { return }
        navigation = nil
        continuation.resume(with: result)
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finishNavigation(.success(()))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        finishNavigation(.failure(WebFetchError.loadFailed))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        finishNavigation(.failure(WebFetchError.loadFailed))
    }
}
