import Foundation
import Testing
@testable import NotesCore

struct WebFetchSupportTests {
    private let url = URL(string: "https://example.com/post")!

    private func long(_ n: Int) -> String { String(repeating: "字", count: n) }

    // MARK: URL

    @Test(arguments: [
        ("https://example.com/a", true), ("http://example.com", true), ("HTTPS://Example.com", true),
        ("ftp://example.com", false), ("file:///etc/hosts", false), ("mailto:a@b.com", false),
        ("javascript:alert(1)", false), ("https://", false),
    ])
    func onlyHTTPAndHTTPSWithAHostAreFetchable(string: String, expected: Bool) throws {
        let url = try #require(URL(string: string))
        #expect(WebFetchPolicy.isFetchable(url) == expected)
    }

    // MARK: 选正文

    @Test func readabilityTextIsUsedAtTheThreshold() throws {
        let output = WebPageScriptOutput(
            article: .init(title: "Article", text: long(200)), pageTitle: "Page", innerText: "short nav text"
        )
        let chosen = WebPageExtraction.choose(output, url: url)
        #expect(chosen.text == long(200))
        #expect(chosen.title == "Article")
    }

    @Test func shorterReadabilityTextFallsBackToInnerText() throws {
        let output = WebPageScriptOutput(
            article: .init(title: "Article", text: long(199)), pageTitle: "Page", innerText: "the whole page text"
        )
        let chosen = WebPageExtraction.choose(output, url: url)
        #expect(chosen.text == "the whole page text")
        #expect(chosen.title == "Page")
    }

    @Test func readabilityFailureFallsBackToInnerText() throws {
        let output = WebPageScriptOutput(article: nil, pageTitle: "Page", innerText: "body")
        #expect(WebPageExtraction.choose(output, url: url).text == "body")
    }

    @Test func titleFallsBackThroughPageTitleToTheURL() throws {
        let noTitles = WebPageScriptOutput(article: .init(title: " ", text: long(300)), pageTitle: nil, innerText: nil)
        #expect(WebPageExtraction.choose(noTitles, url: url).title == "https://example.com/post")
        let pageOnly = WebPageScriptOutput(article: .init(title: "", text: long(300)), pageTitle: " Page ", innerText: nil)
        #expect(WebPageExtraction.choose(pageOnly, url: url).title == "Page")
    }

    @Test func nothingReadableGivesEmptyTextButStillATitle() {
        let blank = WebPageExtraction.choose(
            WebPageScriptOutput(article: .init(title: "T", text: "  \n "), pageTitle: "P", innerText: "\n\n"), url: url
        )
        #expect(blank.text == "")
        #expect(blank.title == "P")
        let nothing = WebPageExtraction.choose(WebPageScriptOutput(), url: url)
        #expect(nothing.text == "")
        #expect(nothing.title == "https://example.com/post")
    }

    @Test func whitespaceIsTrimmedAndBlankLineRunsCollapse() throws {
        let output = WebPageScriptOutput(innerText: "\n\n  first\n\n\n\n   \nsecond\nthird  \n\n")
        #expect(WebPageExtraction.choose(output, url: url).text == "first\n\nsecond\nthird")
    }

    @Test func scriptOutputDecodesFromJSONIncludingNullArticle() throws {
        let full = try WebPageScriptOutput(json: #"{"article":{"title":"T","text":"body"},"pageTitle":"P","innerText":"I"}"#)
        #expect(full == WebPageScriptOutput(article: .init(title: "T", text: "body"), pageTitle: "P", innerText: "I"))
        let nullArticle = try WebPageScriptOutput(json: #"{"article":null,"pageTitle":"P","innerText":"I"}"#)
        #expect(nullArticle.article == nil)
        #expect(throws: (any Error).self) { try WebPageScriptOutput(json: "not json") }
    }

    // MARK: 并发和超时

    private actor Peak {
        private var current = 0
        private(set) var maximum = 0
        func enter() { current += 1; maximum = max(maximum, current) }
        func leave() { current -= 1 }
    }

    @Test func limiterNeverRunsMoreThanTwoAtOnceButRunsAll() async throws {
        let limiter = FetchLimiter(limit: 2)
        let peak = Peak()
        let done = try await withThrowingTaskGroup(of: Int.self) { group in
            for i in 0..<6 {
                group.addTask {
                    try await limiter.withPermit {
                        await peak.enter()
                        try await Task.sleep(for: .milliseconds(40))
                        await peak.leave()
                        return i
                    }
                }
            }
            var all: [Int] = []
            for try await i in group { all.append(i) }
            return all
        }
        #expect(done.sorted() == Array(0..<6))
        #expect(await peak.maximum == 2)
    }

    @Test func permitIsReleasedWhenTheOperationThrows() async throws {
        let limiter = FetchLimiter(limit: 1)
        struct Boom: Error {}
        await #expect(throws: Boom.self) { try await limiter.withPermit { throw Boom() } }
        let value = try await limiter.withPermit { 7 }
        #expect(value == 7)
    }

    @Test func aCancelledWaiterLeavesTheQueueWithoutTakingAPermit() async throws {
        let limiter = FetchLimiter(limit: 1)
        let holder = Task { try await limiter.withPermit { try await Task.sleep(for: .milliseconds(300)) } }
        try await Task.sleep(for: .milliseconds(50))
        let waiter = Task { try await limiter.withPermit { 1 } }
        try await Task.sleep(for: .milliseconds(50))
        waiter.cancel()
        await #expect(throws: CancellationError.self) { try await waiter.value }
        try await holder.value
        #expect(try await limiter.withPermit { 2 } == 2)
    }

    private actor Flag {
        private(set) var isSet = false
        func set() { isSet = true }
    }

    /// 最多等 5 秒，条件成立就返回。
    private func waitUntil(_ condition: () async -> Bool) async throws {
        for _ in 0..<500 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("等待超时")
    }

    @Test(.timeLimit(.minutes(1)))
    func aCancelledQueuedFetchNeverRunsAndTheNextWaiterStillGetsTheSlot() async throws {
        let limiter = FetchLimiter(limit: 1)
        let ran = Flag()
        let holderStarted = Flag()
        let holder = Task {
            try await limiter.withPermit {
                await holderStarted.set()
                try await Task.sleep(for: .milliseconds(300))
            }
        }
        try await waitUntil { await holderStarted.isSet }
        let cancelled = Task { try await limiter.withPermit { await ran.set() } }
        try await Task.sleep(for: .milliseconds(50))
        let next = Task { try await limiter.withPermit { "next" } }
        try await Task.sleep(for: .milliseconds(50))

        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        try await holder.value
        #expect(try await next.value == "next")
        #expect(await ran.isSet == false)
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellingARunningFetchFreesItsSlotForTheNextWaiter() async throws {
        let limiter = FetchLimiter(limit: 1)
        let started = Flag()
        let running = Task {
            try await limiter.withPermit {
                await started.set()
                try await Task.sleep(for: .seconds(60))
            }
        }
        try await waitUntil { await started.isSet }
        let next = Task { try await limiter.withPermit { "next" } }
        try await Task.sleep(for: .milliseconds(50))

        running.cancel()
        await #expect(throws: CancellationError.self) { try await running.value }
        #expect(try await next.value == "next")
    }

    @Test(.timeLimit(.minutes(1)))
    func aTimedOutFetchFreesItsSlot() async throws {
        // 和 WebPageFetcher 一样：拿到位置之后才开始算时限
        let limiter = FetchLimiter(limit: 1)
        await #expect(throws: WebFetchError.timedOut) {
            try await limiter.withPermit {
                try await withFetchTimeout(.milliseconds(50)) {
                    try await Task.sleep(for: .seconds(60))
                    return 1
                }
            }
        }
        #expect(try await limiter.withPermit { 7 } == 7)
    }

    @Test func timeoutCancelsASlowOperation() async throws {
        let started = ContinuousClock.now
        await #expect(throws: WebFetchError.timedOut) {
            try await withFetchTimeout(.milliseconds(50)) {
                try await Task.sleep(for: .seconds(30))
                return 1
            }
        }
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    @Test func fetchTimeoutIsWithTimeoutWithTheFetchErrorType() async throws {
        #expect(try await withFetchTimeout(.seconds(5)) { 42 } == 42)
        await #expect(throws: WebFetchError.timedOut) {
            try await withFetchTimeout(.milliseconds(50)) { await Self.neverReturns() }
        }
    }

    // MARK: 超时和取消不依赖 operation 配合

    /// 永远不返回、也不响应取消的等待，模拟页面脚本死循环时的 `callAsyncJavaScript`。
    private static func neverReturns() async -> Int {
        await withCheckedContinuation { (_: CheckedContinuation<Int, Never>) in }
    }

    @Test(.timeLimit(.minutes(1)))
    func aHungFetchIsTimedOutAndItsSlotIsFreed() async throws {
        let runner = FetchRunner(limit: 1, timeout: .milliseconds(100))
        await #expect(throws: WebFetchError.timedOut) {
            try await runner.run { await Self.neverReturns() }
        }
        #expect(try await runner.run { 7 } == 7)
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellingAHungFetchFreesItsSlot() async throws {
        let runner = FetchRunner(limit: 1, timeout: .seconds(60))
        let hung = Task { try await runner.run { await Self.neverReturns() } }
        try await Task.sleep(for: .milliseconds(50))
        let next = Task { try await runner.run { "next" } }
        try await Task.sleep(for: .milliseconds(50))
        hung.cancel()
        await #expect(throws: CancellationError.self) { try await hung.value }
        #expect(try await next.value == "next")
    }

    @Test(.timeLimit(.minutes(1)))
    func timeQueuedBehindAnotherFetchDoesNotCountTowardsTheTimeout() async throws {
        // 1 个位置，时限 400 ms，两个任务各要 250 ms：第二个排队 250 ms 再跑 250 ms，总共超过时限，
        // 但它自己的 250 ms 没超，所以不能超时
        let runner = FetchRunner(limit: 1, timeout: .milliseconds(400))
        async let first: Int = runner.run { try await Task.sleep(for: .milliseconds(250)); return 1 }
        try await Task.sleep(for: .milliseconds(50))
        async let second: Int = runner.run { try await Task.sleep(for: .milliseconds(250)); return 2 }
        #expect(try await first == 1)
        #expect(try await second == 2)
    }
}
