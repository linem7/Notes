import Foundation
import NotesCore
import WebKit

/// 离屏 WKWebView 抓网页（ARCHITECTURE §6，ADR-0002）：不带用户的 cookie，等页面渲染后用
/// Readability.js 抽正文，再拍一份 PDF 快照。限流、超时、选正文的规则在 NotesCore 里（有单元测试），
/// 这里只负责 WebKit。
final class WebPageFetcher: WebPageFetching {
    private let limiter = FetchLimiter(limit: WebFetchPolicy.maxConcurrent)

    init() {}

    func fetch(_ url: URL) async throws -> WebPageResult {
        guard WebFetchPolicy.isFetchable(url) else { throw WebFetchError.invalidURL }
        return try await limiter.withPermit {
            // 20 秒的总时限从拿到位置之后开始算，排队的时间不算
            try await withFetchTimeout(WebFetchPolicy.timeout) {
                try await PageLoader.load(url)
            }
        }
    }
}

/// 一次抓取用一个 WKWebView，用完就丢。WebKit 只能在主线程用。
@MainActor
private final class PageLoader: NSObject, WKNavigationDelegate {
    private let webView: WKWebView
    private var navigation: CheckedContinuation<Void, Error>?

    private override init() {
        let configuration = WKWebViewConfiguration()
        // 非持久的 data store：不读也不写用户的 cookie 和缓存
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1_024, height: 768), configuration: configuration)
        super.init()
        webView.navigationDelegate = self
    }

    static func load(_ url: URL) async throws -> WebPageResult {
        let loader = PageLoader()
        return try await loader.run(url)
    }

    private func run(_ url: URL) async throws -> WebPageResult {
        defer { webView.stopLoading() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                navigation = continuation
                webView.load(URLRequest(url: url))
            }
        } onCancel: {
            Task { @MainActor in self.finishNavigation(.failure(CancellationError())) }
        }

        // didFinish 之后再等一会儿，给靠 JavaScript 渲染的页面时间
        try await Task.sleep(for: WebFetchPolicy.settleDelay)

        let output = try await extract()
        guard let chosen = WebPageExtraction.choose(output, url: url) else { throw WebFetchError.noText }
        // 快照失败不影响正文
        let pdf = try? await webView.pdf(configuration: WKPDFConfiguration())
        return WebPageResult(title: chosen.title, text: chosen.text, pdfData: pdf)
    }

    /// 在 App 自己的 content world 里跑 Readability，页面脚本碰不到它；失败时 article 是 null。
    private func extract() async throws -> WebPageScriptOutput {
        guard let scriptURL = Bundle.main.url(forResource: "Readability", withExtension: "js"),
              let readability = try? String(contentsOf: scriptURL, encoding: .utf8)
        else { throw WebFetchError.loadFailed }

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

    private func finishNavigation(_ result: Result<Void, Error>) {
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
