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
        private(set) var current = 0
        private(set) var maximum = 0
        func enter() { current += 1; maximum = max(maximum, current) }
        func leave() { current -= 1 }
    }

    @Test(.timeLimit(.minutes(1)))
    func limiterNeverRunsMoreThanTwoAtOnceButRunsAll() async throws {
        let limiter = FetchLimiter(limit: 2)
        let peak = Peak()
        let gate = Gate()
        let tasks = (0..<6).map { i in
            Task {
                try await limiter.withPermit {
                    await peak.enter()
                    await gate.wait()
                    await peak.leave()
                    return i
                }
            }
        }
        // 两个占着位置、四个在排队时，门还关着：此刻并发数就是 2
        try await waitUntil {
            let waiting = await limiter.waitingCount
            let current = await peak.current
            return waiting == 4 && current == 2
        }
        #expect(await limiter.runningCount == 2)
        await gate.open()
        var done: [Int] = []
        for task in tasks { done.append(try await task.value) }
        #expect(done.sorted() == Array(0..<6))
        #expect(await peak.maximum == 2)
        #expect(await limiter.runningCount == 0)
    }

    @Test func permitIsReleasedWhenTheOperationThrows() async throws {
        let limiter = FetchLimiter(limit: 1)
        struct Boom: Error {}
        await #expect(throws: Boom.self) { try await limiter.withPermit { throw Boom() } }
        let value = try await limiter.withPermit { 7 }
        #expect(value == 7)
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

    /// 手动开关：`wait()` 一直等到 `open()`，不依赖睡眠。
    private actor Gate {
        private var isOpen = false
        private var continuations: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { continuations.append($0) }
        }

        func open() {
            isOpen = true
            for continuation in continuations { continuation.resume() }
            continuations = []
        }
    }

    /// 占住唯一的位置，直到 `release` 开门。返回的 Task 在占住位置之后才返回。
    private func hold(_ limiter: FetchLimiter, until release: Gate) async throws -> Task<Void, any Error> {
        let started = Flag()
        let holder = Task {
            try await limiter.withPermit {
                await started.set()
                await release.wait()
            }
        }
        try await waitUntil { await started.isSet }
        return holder
    }

    @Test(.timeLimit(.minutes(1)))
    func aCancelledQueuedFetchNeverRunsAndTheNextWaiterStillGetsTheSlot() async throws {
        let limiter = FetchLimiter(limit: 1)
        let gate = Gate()
        let ran = Flag()
        let holder = try await hold(limiter, until: gate)
        let cancelled = Task { try await limiter.withPermit { await ran.set() } }
        try await waitUntil { await limiter.waitingCount == 1 }
        let next = Task { try await limiter.withPermit { "next" } }
        try await waitUntil { await limiter.waitingCount == 2 }

        // 取消和放位置几乎同时发生：不管谁先到，被取消的都不能执行，位置要传给下一个
        cancelled.cancel()
        await gate.open()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        try await holder.value
        #expect(try await next.value == "next")
        #expect(await ran.isSet == false)
    }

    @Test(.timeLimit(.minutes(1)))
    func cancelFirstThenRelease_theQueuedFetchLeavesAndNeverRuns() async throws {
        let limiter = FetchLimiter(limit: 1)
        let gate = Gate()
        let ran = Flag()
        let holder = try await hold(limiter, until: gate)
        let cancelled = Task { try await limiter.withPermit { await ran.set() } }
        try await waitUntil { await limiter.waitingCount == 1 }
        let next = Task { try await limiter.withPermit { "next" } }
        try await waitUntil { await limiter.waitingCount == 2 }

        // 先取消，等它真的离开队列，再放位置
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        try await waitUntil { await limiter.waitingCount == 1 }
        await gate.open()
        try await holder.value
        #expect(try await next.value == "next")
        #expect(await ran.isSet == false)
        #expect(try await limiter.withPermit { 2 } == 2)
    }

    /// 钩子的控制：`arm()` 之后第一次有人拿到位置时停在钩子里，直到 `gate` 开门。
    private actor HookControl {
        private var armed = false
        private(set) var reached = false
        let gate = Gate()

        func arm() { armed = true }
        func pass() async {
            guard armed else { return }
            armed = false
            reached = true
            await gate.wait()
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func releaseFirstThenCancel_theCancelledFetchHandsThePermitOnWithoutRunning() async throws {
        let control = HookControl()
        let limiter = FetchLimiter(limit: 1, afterAcquire: { await control.pass() })
        let holderGate = Gate()
        let ran = Flag()
        let holder = try await hold(limiter, until: holderGate)
        await control.arm()
        let cancelled = Task { try await limiter.withPermit { await ran.set() } }
        try await waitUntil { await limiter.waitingCount == 1 }
        let next = Task { try await limiter.withPermit { "next" } }
        try await waitUntil { await limiter.waitingCount == 2 }

        // 先放位置：位置交到被取消的任务手上，它停在钩子里；这时才取消它
        await holderGate.open()
        try await holder.value
        try await waitUntil { await control.reached }
        cancelled.cancel()
        await control.gate.open()

        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(try await next.value == "next")
        #expect(await ran.isSet == false)
        #expect(await limiter.waitingCount == 0)
        #expect(try await limiter.withPermit { 3 } == 3)
    }

    @Test(.timeLimit(.minutes(1)))
    func aTaskCancelledBeforeReachingTheLimiterNeverRunsAndTakesNoPermit() async throws {
        let limiter = FetchLimiter(limit: 1)
        let ran = Flag()
        let start = Gate()
        let task = Task {
            await start.wait()   // 不响应取消：任务到达限流器时已经是被取消的状态
            return try await limiter.withPermit { await ran.set(); return 1 }
        }
        task.cancel()
        await start.open()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await ran.isSet == false)
        #expect(await limiter.waitingCount == 0)
        // 空位没有被占
        #expect(try await limiter.withPermit { 2 } == 2)
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
        try await waitUntil { await limiter.waitingCount == 1 }

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

    @Test(.timeLimit(.minutes(1)))
    func timeoutCancelsASlowOperation() async throws {
        let started = ContinuousClock.now
        await #expect(throws: WebFetchError.timedOut) {
            try await withFetchTimeout(.milliseconds(50)) {
                try await Task.sleep(for: .seconds(30))
                return 1
            }
        }
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    @Test(.timeLimit(.minutes(1)))
    func fetchTimeoutIsWithTimeoutWithTheFetchErrorType() async throws {
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
        let started = Flag()
        let hung = Task { try await runner.run { await started.set(); return await Self.neverReturns() } }
        try await waitUntil { await started.isSet }
        let next = Task { try await runner.run { "next" } }
        try await waitUntil { await runner.limiter.waitingCount == 1 }
        hung.cancel()
        await #expect(throws: CancellationError.self) { try await hung.value }
        #expect(try await next.value == "next")
        #expect(await runner.limiter.runningCount == 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func timeQueuedBehindAnotherFetchDoesNotCountTowardsTheTimeout() async throws {
        // 1 个位置，时限 300 ms。占位置的任务直接走限流器（不受抓取时限约束），第二个抓取排队超过 700 ms，
        // 也就是远超时限，然后放行、第二个立刻跑完：排队的时间不算，所以第二个不能超时
        let runner = FetchRunner(limit: 1, timeout: .milliseconds(300))
        let gate = Gate()
        let started = Flag()
        let first = Task { try await runner.limiter.withPermit { await started.set(); await gate.wait(); return 1 } }
        try await waitUntil { await started.isSet }
        let second = Task { try await runner.run { 2 } }
        try await waitUntil { await runner.limiter.waitingCount == 1 }
        try await Task.sleep(for: .milliseconds(700))
        await gate.open()
        #expect(try await first.value == 1)
        #expect(try await second.value == 2)
    }
}
