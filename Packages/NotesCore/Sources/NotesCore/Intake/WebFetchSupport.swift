import Foundation
import Synchronization

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
    private var running = 0
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []

    public init(limit: Int = WebFetchPolicy.maxConcurrent) {
        self.limit = limit
    }

    public func withPermit<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        try await acquire()
        defer { release() }
        return try await operation()
    }

    private func acquire() async throws {
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
///
/// 两种情况都**立刻返回，不等 `operation` 结束**，并且取消 `operation`：`operation` 里有不响应取消的等待
/// （比如 WKWebView 的 `callAsyncJavaScript`，页面脚本死循环时永远不返回）时，超时和取消照样生效。
/// 不用 task group：它会等所有子任务结束，等于把不响应取消的子任务的时间也算进来。
public func withFetchTimeout<T: Sendable>(
    _ duration: Duration,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    let race = FetchRace<T>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, any Error>) in
            race.setContinuation(continuation)
            race.add(Task {
                do {
                    race.finish(.success(try await operation()))
                } catch {
                    race.finish(.failure(error))
                }
            })
            race.add(Task {
                do {
                    try await Task.sleep(for: duration)
                } catch {
                    return
                }
                race.finish(.failure(WebFetchError.timedOut))
            })
        }
    } onCancel: {
        race.finish(.failure(CancellationError()))
    }
}

/// 一次比赛：第一个 `finish` 决定结果，只恢复一次 continuation，并取消另一个任务。
private final class FetchRace<T: Sendable>: Sendable {
    private struct State {
        var continuation: CheckedContinuation<T, any Error>?
        var result: Result<T, any Error>?
        var tasks: [Task<Void, Never>] = []
    }

    private let state = Mutex(State())

    func setContinuation(_ continuation: CheckedContinuation<T, any Error>) {
        let early = state.withLock { state -> Result<T, any Error>? in
            if let result = state.result { return result }
            state.continuation = continuation
            return nil
        }
        // 取消赶在 continuation 建好之前：现在补上
        if let early { continuation.resume(with: early) }
    }

    func add(_ task: Task<Void, Never>) {
        let alreadyFinished = state.withLock { state -> Bool in
            if state.result != nil { return true }
            state.tasks.append(task)
            return false
        }
        if alreadyFinished { task.cancel() }
    }

    func finish(_ result: Result<T, any Error>) {
        let (continuation, tasks) = state.withLock { state -> (CheckedContinuation<T, any Error>?, [Task<Void, Never>]) in
            if state.result != nil { return (nil, []) }
            state.result = result
            let taken = (state.continuation, state.tasks)
            state.continuation = nil
            state.tasks = []
            return taken
        }
        continuation?.resume(with: result)
        for task in tasks { task.cancel() }
    }
}

/// 一次抓取的完整流程：先在限流器外排队，拿到位置之后才开始算 20 秒（排队的时间不算），
/// 超时或被取消时立刻放掉位置。`load` 由 App 注入（WKWebView），测试里换成假的。
public struct FetchRunner: Sendable {
    private let limiter: FetchLimiter
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
