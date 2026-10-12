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
        let chosen = try #require(WebPageExtraction.choose(output, url: url))
        #expect(chosen.text == long(200))
        #expect(chosen.title == "Article")
    }

    @Test func shorterReadabilityTextFallsBackToInnerText() throws {
        let output = WebPageScriptOutput(
            article: .init(title: "Article", text: long(199)), pageTitle: "Page", innerText: "the whole page text"
        )
        let chosen = try #require(WebPageExtraction.choose(output, url: url))
        #expect(chosen.text == "the whole page text")
        #expect(chosen.title == "Page")
    }

    @Test func readabilityFailureFallsBackToInnerText() throws {
        let output = WebPageScriptOutput(article: nil, pageTitle: "Page", innerText: "body")
        #expect(WebPageExtraction.choose(output, url: url)?.text == "body")
    }

    @Test func titleFallsBackThroughPageTitleToTheURL() throws {
        let noTitles = WebPageScriptOutput(article: .init(title: " ", text: long(300)), pageTitle: nil, innerText: nil)
        #expect(WebPageExtraction.choose(noTitles, url: url)?.title == "https://example.com/post")
        let pageOnly = WebPageScriptOutput(article: .init(title: "", text: long(300)), pageTitle: " Page ", innerText: nil)
        #expect(WebPageExtraction.choose(pageOnly, url: url)?.title == "Page")
    }

    @Test func nothingReadableGivesNil() {
        #expect(WebPageExtraction.choose(WebPageScriptOutput(article: .init(title: "T", text: "  \n "), pageTitle: "P", innerText: "\n\n"), url: url) == nil)
        #expect(WebPageExtraction.choose(WebPageScriptOutput(), url: url) == nil)
    }

    @Test func whitespaceIsTrimmedAndBlankLineRunsCollapse() throws {
        let output = WebPageScriptOutput(innerText: "\n\n  first\n\n\n\n   \nsecond\nthird  \n\n")
        #expect(WebPageExtraction.choose(output, url: url)?.text == "first\n\nsecond\nthird")
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

    @Test func fastOperationsPassThroughTheTimeout() async throws {
        #expect(try await withFetchTimeout(.seconds(5)) { 42 } == 42)
        struct Boom: Error {}
        await #expect(throws: Boom.self) { try await withFetchTimeout(.seconds(5)) { throw Boom() } }
    }
}
