import Foundation

/// 网页抓取里不依赖 WebKit 的部分（ARCHITECTURE §6），放在 NotesCore 是为了能在 `swift test` 里测。
/// App/Web/WebPageFetcher 只负责 WKWebView 本身。
public enum WebFetchError: Error, Equatable, Sendable {
    /// 不是 http/https 链接。
    case invalidURL
    /// 超过总时限（20 秒）。
    case timedOut
    /// 页面没加载出来（网络错误、拒绝连接、证书错误……）。
    case loadFailed
}

public enum WebFetchPolicy {
    /// 单个链接的总时限（SPEC §3.2）。
    public static let timeout: Duration = .seconds(20)
    /// didFinish 之后再等这么久，给前端渲染（ARCHITECTURE §6）。
    public static let settleDelay: Duration = .seconds(1)
    /// 最多同时抓几个。
    public static let maxConcurrent = 2
    /// PDF 快照单独的时限：拍不出来可以不要快照，不能拖住整次抓取。
    public static let snapshotTimeout: Duration = .seconds(5)

    public static func isFetchable(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        return !(url.host ?? "").isEmpty
    }
}

/// 页面里跑的脚本交回来的 JSON：Readability 的结果（失败时是 null）加上 `document.title` 和 `innerText`。
public struct WebPageScriptOutput: Decodable, Equatable, Sendable {
    public struct Article: Decodable, Equatable, Sendable {
        public var title: String?
        public var text: String?
        public init(title: String? = nil, text: String? = nil) {
            self.title = title
            self.text = text
        }
    }

    public var article: Article?
    public var pageTitle: String?
    public var innerText: String?

    public init(article: Article? = nil, pageTitle: String? = nil, innerText: String? = nil) {
        self.article = article
        self.pageTitle = pageTitle
        self.innerText = innerText
    }

    public init(json: String) throws {
        self = try JSONDecoder().decode(Self.self, from: Data(json.utf8))
    }
}

public enum WebPageExtraction {
    /// Readability 的正文少于这么多字符就退回 `innerText`（ARCHITECTURE §6）。
    public static let minimumArticleLength = 200

    /// 选正文：Readability 够长就用它，否则用 innerText；都是空的时 text 为 ""（页面加载了但没有正文，
    /// `MaterialIntake` 会把它映射成 `pageHasNoText`，快照照样保留）。
    /// 标题依次取 Readability 的（只在用了它的正文时）、`document.title`、Readability 的、URL。
    public static func choose(_ output: WebPageScriptOutput, url: URL) -> (title: String, text: String) {
        let article = normalize(output.article?.text ?? "")
        let inner = normalize(output.innerText ?? "")
        let usesArticle = article.count >= minimumArticleLength
        let text = usesArticle ? article : inner

        let articleTitle = trim(output.article?.title ?? "")
        let pageTitle = trim(output.pageTitle ?? "")
        let title = [usesArticle ? articleTitle : "", pageTitle, articleTitle].first { !$0.isEmpty }
        return (title ?? url.absoluteString, text)
    }

    private static func trim(_ string: String) -> String {
        string.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 去掉首尾空白，连续的空行压成一个。
    private static func normalize(_ text: String) -> String {
        trim(text).replacingOccurrences(of: "\\n[ \\t]*(\\n[ \\t]*){2,}", with: "\n\n", options: .regularExpression)
    }
}

/// 限制同时进行的抓取个数；等位置的任务被取消时马上退出。
public actor FetchLimiter {
    private let limit: Int
    /// 测试钩子：位置到手之后、检查取消之前调用，用来把「位置先到、取消后到」这个顺序卡住。
    private let afterAcquire: (@Sendable () async -> Void)?
    private var running = 0
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []

    public init(limit: Int = WebFetchPolicy.maxConcurrent) {
        self.limit = limit
        self.afterAcquire = nil
    }

    init(limit: Int, afterAcquire: @escaping @Sendable () async -> Void) {
        self.limit = limit
        self.afterAcquire = afterAcquire
    }

    /// 正在排队的任务数（测试用：等它排上队再取消，不靠睡眠碰运气）。
    var waitingCount: Int { waiters.count }
    /// 正在占着位置的任务数（测试用）。
    var runningCount: Int { running }

    public func withPermit<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        try await acquire()
        defer { release() }
        await afterAcquire?()
        // 排队时被取消，但位置在取消生效之前就交到了手上（`onCancel` 要先跳回 actor 才能把它移出队列）：
        // 不执行，`defer` 把位置交给下一个
        try Task.checkCancellation()
        return try await operation()
    }

    private func acquire() async throws {
        // 到达限流器之前就已经被取消的，空位也不能拿
        try Task.checkCancellation()
        if running < limit {
            running += 1
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters.append((id, continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func release() {
        if waiters.isEmpty {
            running -= 1
        } else {
            // 把位置直接交给下一个等待的任务
            waiters.removeFirst().continuation.resume()
        }
    }
}

/// 超过 `duration` 还没完成就抛 `WebFetchError.timedOut`；调用方被取消就抛 `CancellationError`。
/// 就是 `withTimeout`，只是把超时错误换成抓取的错误类型。
public func withFetchTimeout<T: Sendable>(
    _ duration: Duration,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    do {
        return try await withTimeout(duration, operation)
    } catch is TimeoutError {
        throw WebFetchError.timedOut
    }
}

/// 一次抓取的完整流程：先在限流器外排队，拿到位置之后才开始算 20 秒（排队的时间不算），
/// 超时或被取消时立刻放掉位置。`load` 由 App 注入（WKWebView），测试里换成假的。
public struct FetchRunner: Sendable {
    let limiter: FetchLimiter
    private let timeout: Duration

    public init(limit: Int = WebFetchPolicy.maxConcurrent, timeout: Duration = WebFetchPolicy.timeout) {
        self.limiter = FetchLimiter(limit: limit)
        self.timeout = timeout
    }

    public func run<T: Sendable>(_ load: @escaping @Sendable () async throws -> T) async throws -> T {
        try await limiter.withPermit {
            try await withFetchTimeout(timeout, load)
        }
    }
}
