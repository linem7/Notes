import Foundation
import Synchronization
import Testing
@testable import NotesCore

/// 假的模型：记下收到的参数，按剧本吐出片段或错误。
private final class StubModel: OrganizeModelClient {
    struct Call: Sendable {
        var system: String
        var user: String
        var modelID: String
        var apiKey: String
        var jsonMode: Bool
    }

    enum Script: Sendable {
        case fragments([String])
        case fail([String], ChatError)
        /// 一直等到被取消
        case hang
    }

    private let script: Script
    private let recorded = Mutex<[Call]>([])
    private let cancelled = Mutex(false)

    init(_ script: Script) { self.script = script }

    var calls: [Call] { recorded.withLock { $0 } }
    var wasCancelled: Bool { cancelled.withLock { $0 } }

    func complete(
        system: String, user: String, modelID: String, connection: Connection, apiKey: String, jsonMode: Bool
    ) -> AsyncThrowingStream<String, any Error> {
        recorded.withLock { $0.append(Call(system: system, user: user, modelID: modelID, apiKey: apiKey, jsonMode: jsonMode)) }
        return AsyncThrowingStream { continuation in
            let task = Task {
                switch script {
                case .fragments(let fragments):
                    for fragment in fragments { continuation.yield(fragment) }
                    continuation.finish()
                case .fail(let fragments, let error):
                    for fragment in fragments { continuation.yield(fragment) }
                    continuation.finish(throwing: error)
                case .hang:
                    while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
                    continuation.finish(throwing: CancellationError())
                }
            }
            continuation.onTermination = { [self] _ in
                cancelled.withLock { $0 = true }
                task.cancel()
            }
        }
    }
}

struct OrganizerTests {
    private let now = Date(timeIntervalSince1970: 1_791_806_400)
    private let utc = TimeZone(identifier: "UTC")!

    private func organize(
        _ model: StubModel,
        input: String = "Send the contract to Alex by Thursday",
        materials: [PromptMaterial] = [],
        userPrompt: String = OrganizePrompt.default,
        onProgress: (@Sendable (Int) -> Void)? = nil
    ) async throws -> [Draft] {
        try await Organizer(client: model).organize(
            input: input, promptMaterials: materials, connection: .deepSeek(), modelID: "deepseek-flash", apiKey: "sk-test",
            userPrompt: userPrompt, now: now, timeZone: utc, onProgress: onProgress
        )
    }

    @Test func sendsTheAssembledPromptsInJSONMode() async throws {
        let model = StubModel(.fragments(["{\"notes\": []}"]))
        let material = PromptMaterial(kind: .file, name: "a.txt", text: "hi")
        _ = try await organize(model, materials: [material], userPrompt: "CUSTOM")

        let call = try #require(model.calls.first)
        #expect(call.system == OrganizePrompt.system(now: now, timeZone: utc, prompt: "CUSTOM"))
        #expect(call.user == OrganizePrompt.userMessage(input: "Send the contract to Alex by Thursday", materials: [material]))
        #expect(call.modelID == "deepseek-flash")
        #expect(call.apiKey == "sk-test")
        #expect(call.jsonMode)
    }

    @Test func joinsFragmentsAndParsesTheDrafts() async throws {
        let model = StubModel(.fragments([
            "```json\n{\"notes\": [{\"title\": \"Send the contract to Alex\", ",
            "\"due\": \"2026-10-15\", \"time\": null, \"detail\": \"- email\", \"materials\": [1]}]}\n```",
        ]))
        let drafts = try await organize(model, materials: [PromptMaterial(kind: .file, name: "a.txt", text: "hi")])
        #expect(drafts.count == 1)
        #expect(drafts[0].title == "Send the contract to Alex")
        #expect(drafts[0].due == DueDate(day: "2026-10-15", time: nil))
        #expect(drafts[0].materialIndices == [0])
    }

    @Test func unparsableOutputGivesAFallbackDraftInsteadOfAnError() async throws {
        let model = StubModel(.fragments(["not json at all"]))
        let drafts = try await organize(model, input: "Call the dentist\nTomorrow")
        #expect(drafts.count == 1)
        #expect(drafts[0].title == "Call the dentist")
        #expect(drafts[0].detail == "not json at all")
    }

    @Test func reportsProgressAsTheTextArrives() async throws {
        let model = StubModel(.fragments(["{\"notes\"", ": []}"]))
        let seen = Mutex<[Int]>([])
        _ = try await organize(model) { count in seen.withLock { $0.append(count) } }
        #expect(seen.withLock { $0 } == [8, 13])
    }

    @Test func modelErrorsArePassedThrough() async throws {
        await #expect(throws: ChatError.authentication) {
            try await organize(StubModel(.fail([], .authentication)))
        }
        await #expect(throws: ChatError.network) {
            try await organize(StubModel(.fail(["{\"notes\""], .network)))
        }
    }

    @Test func cancellingStopsTheModelCallAndThrowsCancellationError() async throws {
        let model = StubModel(.hang)
        let task = Task { try await organize(model) }
        for _ in 0..<500 where model.calls.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        task.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
        for _ in 0..<500 where !model.wasCancelled { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.wasCancelled)
    }

    // MARK: 只有 Material

    @Test func materialOnlyInputOmitsTheInputBlockAndTitlesTheFallbackAfterTheFirstMaterial() async throws {
        let model = StubModel(.fragments(["sorry, no JSON"]))
        let materials = [
            PromptMaterial(kind: .file, name: "contract.pdf", text: "Clause 1"),
            PromptMaterial(kind: .file, name: "quote.xlsx"),
        ]
        let drafts = try await organize(model, input: "", materials: materials)

        let call = try #require(model.calls.first)
        #expect(!call.user.contains("<input>"))
        #expect(call.user.hasPrefix("<material index=\"1\" kind=\"file\" name=\"contract.pdf\">"))
        #expect(drafts.count == 1)
        #expect(drafts[0].title == "contract.pdf")
        #expect(drafts[0].detail == "sorry, no JSON")
        #expect(drafts[0].materialIndices == [0, 1])
    }

    @Test func materialOnlyInputStillParsesAGoodResponse() async throws {
        let model = StubModel(.fragments(["{\"notes\": [{\"title\": \"Review the contract\", \"materials\": [1]}]}"]))
        let drafts = try await organize(model, input: " ", materials: [PromptMaterial(kind: .file, name: "contract.pdf", text: "x")])
        #expect(drafts.map(\.title) == ["Review the contract"])
        #expect(drafts[0].materialIndices == [0])
    }

    @Test func truncatedJSONFromTheStreamGivesAFallbackDraftWithoutThrowing() async throws {
        let model = StubModel(.fragments([
            "{\"notes\": [{\"title\": \"Send the contract\", \"due\": \"2026-10",
            "-15\", \"detail\": \"- email",
        ]))
        let drafts = try await organize(model, input: "Send the contract to Alex\nThursday")
        #expect(drafts.count == 1)
        #expect(drafts[0].title == "Send the contract to Alex")
        #expect(drafts[0].detail.hasPrefix("{\"notes\": [{\"title\": \"Send the contract\""))
        #expect(drafts[0].due == nil)
    }

    @Test func progressCountsCharactersNotBytes() async throws {
        let model = StubModel(.fragments(["你好", "世界!"]))
        let seen = Mutex<[Int]>([])
        _ = try await organize(model) { count in seen.withLock { $0.append(count) } }
        #expect(seen.withLock { $0 } == [2, 5])
    }
}

struct OrganizerMaterialTests {
    private let now = Date(timeIntervalSince1970: 1_791_806_400)
    private let utc = TimeZone(identifier: "UTC")!
    private let marker = MaterialBudget.truncationMarker

    private func file(_ name: String, text: String?) -> OrganizeMaterial {
        OrganizeMaterial(
            staged: StagedMaterial(kind: .file, displayName: name, fileURL: URL(fileURLWithPath: "/tmp/\(name)")),
            prepared: PreparedText(state: text.map { .ready($0) } ?? .unavailable(.notReadable))
        )
    }

    private func page(_ url: String, title: String?, text: String?, state: ReadableTextState? = nil) -> OrganizeMaterial {
        OrganizeMaterial(
            staged: StagedMaterial(kind: .webPage, displayName: url, url: URL(string: url)),
            prepared: PreparedText(state: state ?? text.map { .ready($0) } ?? .unavailable(.pageLoadFailed), title: title)
        )
    }

    /// 返回模型收到的 user 消息和得到的 Draft。
    private func run(
        input: String, materials: [OrganizeMaterial], reply: String = "not json"
    ) async throws -> (user: String, drafts: [Draft]) {
        let model = StubModel(.fragments([reply]))
        let drafts = try await Organizer(client: model).organize(
            input: input, materials: materials, connection: .deepSeek(), modelID: "m", apiKey: "k", now: now, timeZone: utc
        )
        return (try #require(model.calls.first).user, drafts)
    }

    @Test func buildsMaterialTagsFromReadyTextAndLeavesTheRestUnreadable() async throws {
        let (user, _) = try await run(input: "Review these", materials: [
            file("contract.pdf", text: "Clause 1"),
            file("quote.xlsx", text: nil),
            page("https://example.com/a", title: "Example Page", text: "Body"),
            page("https://down.example.com", title: nil, text: nil),
            file("scan.png", text: nil),
        ])
        #expect(user == """
        <input>
        Review these
        </input>

        <material index="1" kind="file" name="contract.pdf">
        Clause 1
        </material>

        <material index="2" kind="file" name="quote.xlsx" readable="false"/>

        <material index="3" kind="webpage" url="https://example.com/a" title="Example Page">
        Body
        </material>

        <material index="4" kind="webpage" url="https://down.example.com" title="https://down.example.com" readable="false"/>

        <material index="5" kind="file" name="scan.png" readable="false"/>
        """)
    }

    @Test(arguments: ["", "  \n\t "])
    func emptyOrBlankReadyTextIsSentAsUnreadable(text: String) async throws {
        let (user, _) = try await run(input: "x", materials: [file("blank.txt", text: text)])
        #expect(user.contains("<material index=\"1\" kind=\"file\" name=\"blank.txt\" readable=\"false\"/>"))
        #expect(!user.contains("</material>"))
    }

    @Test func pendingMaterialsAreSentAsUnreadable() async throws {
        let pending = OrganizeMaterial(
            staged: StagedMaterial(kind: .file, displayName: "slow.pdf"), prepared: PreparedText(state: .pending)
        )
        let (user, _) = try await run(input: "x", materials: [pending])
        #expect(user.contains("<material index=\"1\" kind=\"file\" name=\"slow.pdf\" readable=\"false\"/>"))
    }

    // MARK: 截断（ARCHITECTURE §4.1：20,000 / 60,000 / 20,000）

    private func body(of tag: String, in user: String) -> String {
        guard let open = user.range(of: ">\n", range: user.range(of: tag)!.upperBound..<user.endIndex),
              let close = user.range(of: "\n</material>", range: open.upperBound..<user.endIndex) else { return "" }
        return String(user[open.upperBound..<close.lowerBound])
    }

    @Test func aMaterialAtExactlyThePerMaterialLimitIsNotCut() async throws {
        let text = String(repeating: "a", count: 20_000)
        let (user, _) = try await run(input: "x", materials: [file("a.txt", text: text)])
        let sent = body(of: "<material index=\"1\"", in: user)
        #expect(sent == text)
        #expect(!user.contains(marker))
    }

    @Test func aMaterialOneOverThePerMaterialLimitIsCutAndMarked() async throws {
        let (user, _) = try await run(input: "x", materials: [file("a.txt", text: String(repeating: "a", count: 20_001))])
        #expect(body(of: "<material index=\"1\"", in: user) == String(repeating: "a", count: 20_000) + marker)
    }

    @Test func totalLimitCutsLaterMaterialsAndMarksThem() async throws {
        // 前三个各 20,000 刚好用完 60,000；第四个一个字也分不到；第五个没有 Readable Text 不受影响
        let chunk = String(repeating: "b", count: 20_000)
        let (user, _) = try await run(input: "x", materials: [
            file("1.txt", text: chunk), file("2.txt", text: chunk), file("3.txt", text: chunk),
            file("4.txt", text: "tail"), file("5.bin", text: nil),
        ])
        #expect(body(of: "<material index=\"3\"", in: user) == chunk)
        #expect(body(of: "<material index=\"4\"", in: user) == marker)
        #expect(user.contains("<material index=\"5\" kind=\"file\" name=\"5.bin\" readable=\"false\"/>"))
    }

    @Test func totalLimitSplitsInTheMiddleOfAMaterial() async throws {
        let (user, _) = try await run(input: "x", materials: [
            file("1.txt", text: String(repeating: "c", count: 20_000)),
            file("2.txt", text: String(repeating: "d", count: 20_000)),
            file("3.txt", text: String(repeating: "e", count: 19_000)),
            file("4.txt", text: String(repeating: "f", count: 5_000)),
        ])
        #expect(body(of: "<material index=\"3\"", in: user) == String(repeating: "e", count: 19_000))
        #expect(body(of: "<material index=\"4\"", in: user) == String(repeating: "f", count: 1_000) + marker)
    }

    @Test func theInputIsCutAtItsOwnLimit() async throws {
        let exact = String(repeating: "i", count: 20_000)
        let (atLimit, _) = try await run(input: exact, materials: [])
        #expect(atLimit == "<input>\n\(exact)\n</input>")
        let (over, _) = try await run(input: exact + "j", materials: [])
        #expect(over == "<input>\n\(exact)\(marker)\n</input>")
    }

    @Test func theFallbackTitleUsesTheUncutInput() async throws {
        let long = String(repeating: "x", count: 30_000)
        let (_, drafts) = try await run(input: "Call Alex\n" + long, materials: [])
        #expect(drafts[0].title == "Call Alex")
    }

    @Test func materialOnlyInputUsesTheMaterialNameForTheFallbackTitle() async throws {
        let (user, drafts) = try await run(input: "", materials: [
            page("https://example.com/a", title: "Example Page", text: "Body"),
            file("b.pdf", text: "x"),
        ])
        #expect(!user.contains("<input>"))
        #expect(drafts[0].title == "Example Page")
        #expect(drafts[0].materialIndices == [0, 1])
    }

    @Test func draftsPointAtTheMaterialsArray() async throws {
        let reply = #"{"notes": [{"title": "T", "materials": [2]}]}"#
        let (_, drafts) = try await run(input: "x", materials: [file("a.txt", text: "1"), file("b.txt", text: nil)], reply: reply)
        #expect(drafts[0].materialIndices == [1])
    }
}

/// 用真的 OpenAICompatibleClient 加假的传输层：看 Organize 实际发出去的请求。
struct OrganizerRequestTests {
    private func sse(_ content: String) throws -> String {
        let encoded = String(decoding: try JSONEncoder().encode(content), as: UTF8.self)
        return "data: {\"choices\": [{\"index\": 0, \"delta\": {\"content\": \(encoded)}, \"finish_reason\": null}]}\n\n"
            + "data: {\"choices\": [{\"index\": 0, \"delta\": {\"content\": null}, \"finish_reason\": \"stop\"}]}\n\n"
            + "data: [DONE]\n\n"
    }

    private func sentFields(_ connection: Connection, modelID: String) async throws -> (fields: [String: JSONValue], drafts: [Draft]) {
        let reply = #"{"notes": [{"title": "Buy milk", "due": null, "time": null, "detail": "", "materials": []}]}"#
        let transport = StubTransport(body: try sse(reply))
        let drafts = try await Organizer(client: OpenAICompatibleClient(transport: transport)).organize(
            input: "buy milk", promptMaterials: [], connection: connection, modelID: modelID, apiKey: "sk-test"
        )
        let body = try JSONDecoder().decode(JSONValue.self, from: try #require(transport.requests.first?.body))
        guard case .object(let fields) = body else { Issue.record("body 不是对象"); return ([:], drafts) }
        return (fields, drafts)
    }

    @Test func deepSeekGetsJSONModeAndThinkingOffAndNoTemperature() async throws {
        let (fields, drafts) = try await sentFields(.deepSeek(), modelID: "deepseek-flash")
        #expect(drafts.map(\.title) == ["Buy milk"])
        #expect(fields["stream"] == .bool(true))
        #expect(fields["response_format"] == .object(["type": .string("json_object")]))
        #expect(fields["thinking"] == .object(["type": .string("disabled")]))
        #expect(fields["temperature"] == nil)
    }

    @Test func openRouterGetsJSONModeAndReasoningOff() async throws {
        let (fields, _) = try await sentFields(.openRouter(), modelID: "deepseek/deepseek-chat")
        #expect(fields["response_format"] == .object(["type": .string("json_object")]))
        #expect(fields["reasoning"] == .object(["enabled": .bool(false)]))
        #expect(fields["temperature"] == nil)
    }

    @Test func bailianGetsNoJSONModeButThinkingOff() async throws {
        let (fields, _) = try await sentFields(.bailian(), modelID: "qwen-flash")
        #expect(fields["response_format"] == nil)
        #expect(fields["enable_thinking"] == .bool(false))
        #expect(fields["temperature"] == nil)
    }

    @Test func otherServicesGetNoPlatformFields() async throws {
        let custom = Connection.custom(baseURL: URL(string: "http://localhost:11434/v1")!)
        let (fields, _) = try await sentFields(custom, modelID: "llama")
        for field in ["response_format", "thinking", "reasoning", "enable_thinking", "temperature"] {
            #expect(fields[field] == nil, "不应该发送 \(field)")
        }
    }

    @Test func systemAndUserMessagesAreTheOrganizePrompts() async throws {
        let (fields, _) = try await sentFields(.deepSeek(), modelID: "deepseek-flash")
        guard case .array(let messages)? = fields["messages"], messages.count == 2 else {
            Issue.record("messages 不是两条"); return
        }
        guard case .object(let system) = messages[0], case .string(let systemText)? = system["content"],
              case .object(let user) = messages[1], case .string(let userText)? = user["content"] else {
            Issue.record("消息格式不对"); return
        }
        #expect(systemText.hasPrefix("Today is "))
        #expect(systemText.hasSuffix(OrganizePrompt.default))
        #expect(userText == "<input>\nbuy milk\n</input>")
    }
}
