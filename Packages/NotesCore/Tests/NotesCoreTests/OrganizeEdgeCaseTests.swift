import Foundation
import Synchronization
import Testing
@testable import NotesCore

/// Organize 的边界用例：模型输出的怪格式和脏值、取消路径、预算和转义的边界。
/// 流和模型输出都是按协议描述自己构造的，不是官方原文。
struct OrganizeParserEdgeCaseTests {
    private func parse(_ raw: String, input: String = "first line\nsecond", materialCount: Int = 0) -> [Draft] {
        OrganizeResponseParser.parse(raw, input: input, materialNames: (0..<materialCount).map { "m\($0 + 1)" })
    }

    private func note(_ fields: String) -> String { "{\"notes\": [{\(fields)}]}" }

    private func isFallback(_ drafts: [Draft], raw: String) -> Bool {
        drafts.count == 1 && drafts[0].title == "first line" && drafts[0].detail == raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: 宽松解析的顺序

    private let single = "{\"title\": \"A\", \"due\": \"2026-10-15\", \"detail\": \"- x\", \"materials\": [2]}"

    @Test func step1_codeFenceLinesAreStrippedBeforeParsing() {
        let drafts = parse("```json\n\(note("\"title\": \"A\""))\n```", materialCount: 0)
        #expect(drafts.map(\.title) == ["A"])
    }

    @Test func step1_aBareArrayIsAcceptedAsTheNotes() {
        let drafts = parse("[\(single), {\"title\": \"B\"}]", materialCount: 2)
        #expect(drafts.map(\.title) == ["A", "B"])
        #expect(drafts.first?.materialIndices == [1])
        #expect(drafts.last?.materialIndices == [0, 1])
    }

    @Test func step1_aSingleObjectWithoutTheNotesWrapperIsOneNote() {
        let drafts = parse(single, materialCount: 2)
        #expect(drafts.map(\.title) == ["A"])
        #expect(drafts.first?.due == DueDate(day: "2026-10-15"))
    }

    @Test func step1_aFencedBareArrayIsAccepted() {
        #expect(parse("```json\n[\(single)]\n```", materialCount: 2).map(\.title) == ["A"])
    }

    @Test func step2_bracesInsideChatterAreFoundByFirstAndLastBrace() {
        let drafts = parse("Sure, here you go:\n\(note("\"title\": \"A\""))\nAnything else?")
        #expect(drafts.map(\.title) == ["A"])
    }

    @Test func step3_aBareArrayInsideChatterIsFoundByFirstAndLastBracket() {
        let drafts = parse("Here: [\(single), {\"title\": \"B\"}] done", materialCount: 2)
        #expect(drafts.map(\.title) == ["A", "B"])
    }

    @Test(arguments: [
        "Done {ok}\n{\"title\": \"A\"}",
        "{\"title\": \"A\"}\nhope that helps :}",
        "{\"foo\": 1}",
    ])
    func chatterThatContainsItsOwnBracesFallsBack(raw: String) {
        // 锁定现状：闲话里自己带大括号、又没有干净的数组可取时，解析失败，走 fallback，原文放进 Detail
        #expect(isFallback(parse(raw), raw: raw))
    }

    @Test(arguments: [
        "Done {ok}\n{\"notes\": [{\"title\": \"A\"}]}",
        "{\"notes\": [{\"title\": \"A\"}]}\nhope that helps :}",
    ])
    func chatterWithBracesStillRecoversACleanNotesArray(raw: String) {
        // 第 2 步（大括号）失败后，第 3 步（方括号）取到了 notes 数组
        #expect(parse(raw).map(\.title) == ["A"])
    }

    // MARK: 字段类型错误

    @Test func titleThatIsNotAStringDropsTheNote() {
        let raw = "{\"notes\": [{\"title\": 5}, {\"title\": null}, {\"title\": \"ok\"}]}"
        #expect(parse(raw).map(\.title) == ["ok"])
    }

    @Test func nonObjectElementsInNotesAreSkipped() {
        let raw = "{\"notes\": [\"x\", 3, null, {\"title\": \"A\"}]}"
        #expect(parse(raw).map(\.title) == ["A"])
    }

    @Test(arguments: ["null", "5", "[\"a\"]", "{\"a\": 1}"])
    func detailThatIsNotAStringBecomesEmpty(value: String) {
        let drafts = parse(note("\"title\": \"A\", \"detail\": \(value)"))
        #expect(drafts.first?.detail == "")
    }

    @Test(arguments: ["null", "20261015", "true", "[\"2026-10-15\"]"])
    func dueThatIsNotAStringIsEmpty(value: String) {
        let drafts = parse(note("\"title\": \"A\", \"due\": \(value), \"time\": \"09:00\""))
        #expect(drafts.first?.due == nil)
    }

    @Test func aNonexistentDayDropsTheTimeToo() {
        let drafts = parse(note("\"title\": \"A\", \"due\": \"2026-02-30\", \"time\": \"15:00\""))
        #expect(drafts.first?.due == nil)
    }

    // MARK: 脏值

    @Test(arguments: ["09:00\\n", " 09:00 ", "09:00\\r\\n", "\\t09:00"])
    func timeWithSurroundingWhitespaceIsStoredTrimmed(time: String) {
        let drafts = parse(note("\"title\": \"A\", \"due\": \"2026-10-15\", \"time\": \"\(time)\""))
        #expect(drafts.first?.due == DueDate(day: "2026-10-15", time: "09:00"))
    }

    @Test func dayWithSurroundingWhitespaceIsStoredTrimmed() {
        let drafts = parse(note("\"title\": \"A\", \"due\": \" 2026-10-15\\n\""))
        #expect(drafts.first?.due == DueDate(day: "2026-10-15"))
    }

    @Test(arguments: ["٠٩:٠٠", "0٩:00", "09:٠٠", "９:00", "09：00"])
    func nonASCIIDigitsInTimeAreRejected(time: String) {
        let drafts = parse(note("\"title\": \"A\", \"due\": \"2026-10-15\", \"time\": \"\(time)\""))
        #expect(drafts.first?.due == DueDate(day: "2026-10-15", time: nil))
    }

    @Test(arguments: ["٢٠٢٦-١٠-١٥", "２０２６-１０-１５"])
    func nonASCIIDigitsInDayAreRejected(day: String) {
        #expect(parse(note("\"title\": \"A\", \"due\": \"\(day)\"")).first?.due == nil)
    }

    /// 解析器接受的日子，Board 一定也认：两边共用 `DueDate.isValidDay`。
    @Test(arguments: ["0000-01-01", "0001-01-01", "9999-12-31", "2000-02-29", "2100-02-29", "2026-04-31", "2026-12-31"])
    func parserAndBoardAgreeOnWhichDaysExist(day: String) {
        let parsed = parse(note("\"title\": \"A\", \"due\": \"\(day)\"")).first?.due
        #expect((parsed != nil) == DueDate.isValidDay(day))
        let item = NoteWithMaterials(note: Note(title: "A", due: parsed))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let sections = BoardSections.sections(for: [item], today: Date(timeIntervalSince1970: 1_791_806_400), calendar: calendar)
        #expect((parsed == nil) == (sections.first?.section == .noDate))
    }

    // MARK: materials 序号

    @Test(arguments: [
        "[-9223372036854775808]", "[9223372036854775807]", "[1e30]", "[-1e30]", "[1.5]", "[0]", "[-1]", "[3]",
        "[\"1\"]", "[null]", "[true]", "[false]", "[[1]]", "[{\"a\": 1}]", "1", "\"all\"", "null", "{\"a\": 1}",
    ])
    func unusableMaterialNumbersMeanAllAndNeverCrash(value: String) {
        let drafts = parse(note("\"title\": \"A\", \"materials\": \(value)"), materialCount: 2)
        #expect(drafts.first?.materialIndices == [0, 1])
    }

    @Test func usableNumbersSurviveNextToUnusableOnes() {
        let drafts = parse(note("\"title\": \"A\", \"materials\": [2, 1e30, -9223372036854775808, \"x\", 2.0]"), materialCount: 3)
        #expect(drafts.first?.materialIndices == [1])
    }

    // MARK: Title 和内容

    @Test func titleNewlinesAndRepeatedWhitespaceFoldToSingleSpaces() {
        let drafts = parse(note("\"title\": \"  Line one\\n  line   two\\r\\n\\tthree \""))
        #expect(drafts.first?.title == "Line one line two three")
    }

    @Test func aTitleOfOnlyWhitespaceDropsTheNote() {
        #expect(parse(note("\"title\": \" \\n\\t \"")).map(\.title) == ["first line"])   // 条目被丢弃 → fallback
    }

    @Test func chineseEmojiAndUnicodeEscapesSurvive() {
        let raw = note("\"title\": \"把合同发给 Alex \\u53d1\\u9001\", \"detail\": \"- 第一条\\n- 第二条 🙂\"")
        let drafts = parse(raw)
        #expect(drafts.first?.title == "把合同发给 Alex 发送")
        #expect(drafts.first?.detail == "- 第一条\n- 第二条 🙂")
    }
}

struct OrganizePromptEdgeCaseTests {
    @Test func carriageReturnsAndTabsInAttributesBecomeSpaces() {
        let message = OrganizePrompt.userMessage(input: "x", materials: [
            PromptMaterial(kind: .file, name: "a\rb\tc.txt", text: "t"),
        ])
        #expect(message.contains("name=\"a b c.txt\""))
        #expect(!message.contains("\r"))
    }

    @Test(arguments: ["", "   ", "\n\t"])
    func aBlankWebPageTitleFallsBackToTheDisplayName(title: String) {
        let material = OrganizeMaterial(
            staged: StagedMaterial(kind: .webPage, displayName: "https://example.com/a", url: URL(string: "https://example.com/a")),
            prepared: PreparedText(state: .ready("Body"), title: title)
        )
        let prompt = Organizer.promptMaterial(material, text: "Body")
        #expect(prompt.title == nil)
        #expect(prompt.name == "https://example.com/a")
        let message = OrganizePrompt.userMessage(input: "x", materials: [prompt])
        #expect(message.contains("title=\"https://example.com/a\""))
    }

    @Test func aWebPageTitleIsTrimmed() {
        let material = OrganizeMaterial(
            staged: StagedMaterial(kind: .webPage, displayName: "https://example.com/a", url: URL(string: "https://example.com/a")),
            prepared: PreparedText(state: .ready("Body"), title: "  Example \n")
        )
        #expect(Organizer.promptMaterial(material, text: "Body").title == "Example")
    }
}

struct MaterialBudgetEdgeCaseTests {
    private let marker = MaterialBudget.truncationMarker

    @Test(arguments: [0, -5])
    func zeroOrNegativeLimitsCutEverythingWithoutCrashing(limit: Int) {
        let budget = MaterialBudget(perMaterial: limit, total: limit, source: limit)
        let result = budget.apply(source: "abc", materialTexts: ["def", nil, ""])
        #expect(result.source == marker)
        #expect(result.materials == [marker, nil, ""])
    }

    @Test func graphemeClustersAreNeverSplit() {
        // é（e + 组合符）、国旗、家庭 emoji 各算一个字符
        let text = "e\u{301}🇨🇳👨‍👩‍👧x"
        let budget = MaterialBudget(perMaterial: 3, total: 100, source: 100)
        #expect(budget.apply(source: "", materialTexts: [text]).materials == ["e\u{301}🇨🇳👨‍👩‍👧" + marker])
    }

    @Test func crlfCountsAsOneCharacter() {
        let budget = MaterialBudget(perMaterial: 2, total: 100, source: 100)
        #expect(budget.apply(source: "", materialTexts: ["a\r\nb"]).materials == ["a\r\n" + marker])
    }
}

// MARK: - 取消和出错（所有等待都有时限，实现出问题时不会卡住整个测试进程）

private struct ScriptedClient: OrganizeModelClient {
    var fragments: [String] = []
    var error: ChatError?

    func complete(
        system: String, user: String, modelID: String, connection: Connection, apiKey: String, jsonMode: Bool
    ) -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { continuation in
            for fragment in fragments { continuation.yield(fragment) }
            continuation.finish(throwing: error)
        }
    }
}

/// 返回的流永远不出数据，也不理会取消（没有 onTermination）。
private final class DeafClient: OrganizeModelClient {
    private let started = Mutex(false)
    var didStart: Bool { started.withLock { $0 } }

    func complete(
        system: String, user: String, modelID: String, connection: Connection, apiKey: String, jsonMode: Bool
    ) -> AsyncThrowingStream<String, any Error> {
        started.withLock { $0 = true }
        return AsyncThrowingStream { _ in }
    }
}

/// `send` 永远不返回，也不理会取消。真实的 URLSession 是响应取消的，这里是最坏情况。
private final class DeafTransport: HTTPTransport {
    private let started = Mutex(false)
    var didStart: Bool { started.withLock { $0 } }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        started.withLock { $0 = true }
        await withUnsafeContinuation { (_: UnsafeContinuation<Void, Never>) in }
        throw ChatError.network
    }
}

struct OrganizerEdgeCaseTests {
    private let now = Date(timeIntervalSince1970: 1_791_806_400)

    private func organize(
        _ client: any OrganizeModelClient, input: String = "first line\nsecond", materials: [OrganizeMaterial] = []
    ) async throws -> [Draft] {
        try await Organizer(client: client).organize(
            input: input, materials: materials, connection: .deepSeek(), modelID: "m", apiKey: "k",
            now: now, timeZone: TimeZone(identifier: "UTC")!
        )
    }

    private func file(_ name: String, _ state: ReadableTextState) -> OrganizeMaterial {
        OrganizeMaterial(staged: StagedMaterial(kind: .file, displayName: name), prepared: PreparedText(state: state))
    }

    /// 在 Task 里跑 organize，等 `started` 之后取消，最多等 5 秒看它有没有结束。返回它的结果；没结束返回 nil。
    private func cancelledOutcome(
        started: () -> Bool, _ body: @escaping @Sendable () async throws -> [Draft]
    ) async throws -> Result<[Draft], any Error>? {
        let outcome = Mutex<Result<[Draft], any Error>?>(nil)
        let task = Task {
            do {
                let drafts = try await body()
                outcome.withLock { $0 = .success(drafts) }
            } catch {
                outcome.withLock { $0 = .failure(error) }
            }
        }
        for _ in 0..<500 where !started() { try await Task.sleep(for: .milliseconds(10)) }
        #expect(started(), "organize 没有开始调用模型")
        task.cancel()
        for _ in 0..<500 where outcome.withLock({ $0 }) == nil { try await Task.sleep(for: .milliseconds(10)) }
        return outcome.withLock { $0 }
    }

    private func expectCancelled(_ outcome: Result<[Draft], any Error>?) {
        switch outcome {
        case nil: Issue.record("取消之后 5 秒内 organize 没有结束")
        case .success: Issue.record("取消之后不该得到 Draft（也不该是 fallback）")
        case .failure(let error): #expect(error is CancellationError, "应抛 CancellationError：\(error)")
        }
    }

    @Test func cancellingWorksEvenIfTheClientIgnoresCancellation() async throws {
        let client = DeafClient()
        let outcome = try await cancelledOutcome(started: { client.didStart }) { try await self.organize(client) }
        expectCancelled(outcome)
    }

    @Test func cancellingWorksEvenIfTheTransportNeverReturnsFromSend() async throws {
        let transport = DeafTransport()
        let client = OpenAICompatibleClient(transport: transport)
        let outcome = try await cancelledOutcome(started: { transport.didStart }) { try await self.organize(client) }
        expectCancelled(outcome)
    }

    @Test func cancellingWhileTheResponseBodyHangsThrowsCancellationAndClosesTheBody() async throws {
        let transport = HangingTransport()
        let client = OpenAICompatibleClient(transport: transport)
        let outcome = try await cancelledOutcome(started: { transport.bodyIsOpen }) { try await self.organize(client) }
        expectCancelled(outcome)
        try await transport.waitUntil { transport.bodyWasCancelled }
    }

    @Test func aStreamThatFailsAfterPartialOutputThrowsInsteadOfFallingBack() async throws {
        let client = ScriptedClient(fragments: ["{\"notes\": [{\"title\": \"A\""], error: .network)
        await #expect(throws: ChatError.network) {
            _ = try await organize(client)
        }
    }

    @Test func aModelThatReturnsNothingGivesAFallbackWithAnEmptyDetail() async throws {
        let drafts = try await organize(ScriptedClient())
        #expect(drafts.map(\.title) == ["first line"])
        #expect(drafts.map(\.detail) == [""])
    }

    @Test func materialNumbersKeepPointingAtTheOriginalArrayEvenWhenSomeAreUnreadable() async throws {
        let materials = [file("slow.pdf", .pending), file("a.txt", .ready("A")), file("b.xlsx", .unavailable(.notReadable))]
        let reply = "{\"notes\": [{\"title\": \"T1\", \"materials\": [1]}, {\"title\": \"T2\", \"materials\": [3]}, {\"title\": \"T3\"}]}"
        let drafts = try await organize(ScriptedClient(fragments: [reply]), materials: materials)
        #expect(drafts.map(\.materialIndices) == [[0], [2], [0, 1, 2]])
    }
}
