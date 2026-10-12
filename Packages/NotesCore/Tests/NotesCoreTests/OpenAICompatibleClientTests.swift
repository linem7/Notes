import Foundation
import Testing
@testable import NotesCore

/// Fixtures/deepseek-chat-stream.sse 和 Fixtures/deepseek-models.json 是 DeepSeek 官方文档里的原文：
/// https://api-docs.deepseek.com/api/create-chat-completion （Response 的 stream 示例）
/// https://api-docs.deepseek.com/api/list-models （Response 示例）
/// Fixtures/openrouter-models.json：2026-10-09 无鉴权请求 https://openrouter.ai/api/v1/models 的结果，只留了三个模型和几个字段。
/// 其余的流和错误体是按文档描述自己构造的，不是官方原文；构造的地方都有注明。
struct OpenAICompatibleClientTests {
    private let connection = Connection.deepSeek()

    private func collect(
        _ transport: StubTransport,
        connection: Connection? = nil,
        modelID: String = "deepseek-flash",
        system: String = "",
        user: String = "Hi",
        jsonMode: Bool = false
    ) async throws -> [String] {
        let client = OpenAICompatibleClient(transport: transport)
        var fragments: [String] = []
        let stream = client.complete(
            system: system, user: user, modelID: modelID,
            connection: connection ?? self.connection, apiKey: "sk-test", jsonMode: jsonMode
        )
        for try await fragment in stream { fragments.append(fragment) }
        return fragments
    }

    /// 构造的流：每个 chunk 只保留解码用到的字段。
    private func chunk(_ content: String?, finishReason: String? = nil) -> String {
        let contentJSON = content.map { "\"content\": \"\($0)\"" } ?? "\"content\": null"
        let finishJSON = finishReason.map { "\"\($0)\"" } ?? "null"
        return "data: {\"choices\": [{\"index\": 0, \"delta\": {\(contentJSON)}, \"finish_reason\": \(finishJSON)}]}\n\n"
    }

    // MARK: 流解码

    @Test func decodesOfficialStreamExample() async throws {
        let transport = StubTransport(body: try Fixture.string("deepseek-chat-stream.sse"))
        let fragments = try await collect(transport)
        #expect(fragments == ["Hello", "!", " How", " can", " I", " assist", " you", " today", "?"])
    }

    @Test func keepAliveCommentsAndDoneMarkerAreHandled() async throws {
        // 构造的流：排队时的 keep-alive，加上以空行结尾的 [DONE]
        let body = ": keep-alive\n\n" + chunk("Hi") + ": keep-alive\n\n" + chunk(nil, finishReason: "stop") + "data: [DONE]\n\n"
        #expect(try await collect(StubTransport(body: body)) == ["Hi"])
    }

    @Test func doneWithoutFinishReasonStillFinishes() async throws {
        // 构造的流
        #expect(try await collect(StubTransport(body: chunk("Hi") + "data: [DONE]\n\n")) == ["Hi"])
    }

    @Test(arguments: ["length", "tool_calls"])
    func finishReasonsThatEndNormally(raw: String) async throws {
        #expect(try await collect(StubTransport(body: chunk("Hi") + chunk(nil, finishReason: raw))) == ["Hi"])
    }

    @Test(arguments: [
        ("insufficient_system_resource", ChatError.overloaded),
        ("aborted", ChatError.providerError("DeepSeek 中途中止了生成（finish_reason: aborted）")),
        ("content_filter", ChatError.providerError("回答被内容过滤拦截了（finish_reason: content_filter）")),
    ])
    func finishReasonsThatAreErrors(raw: String, expected: ChatError) async throws {
        let transport = StubTransport(body: chunk("Hi") + chunk(nil, finishReason: raw))
        let stream = OpenAICompatibleClient(transport: transport)
            .complete(system: "", user: "Hi", modelID: "deepseek-flash", connection: connection, apiKey: "sk-test", jsonMode: false)
        var fragments: [String] = []
        await #expect(throws: expected) {
            for try await fragment in stream { fragments.append(fragment) }
        }
        #expect(fragments == ["Hi"])
    }

    @Test func streamEndingWithoutFinishIsNetworkError() async throws {
        // 构造的流：连接在中途断开
        await #expect(throws: ChatError.network) {
            try await collect(StubTransport(body: chunk("Hi")))
        }
    }

    @Test func disconnectAfterFinishReasonIsANormalEnd() async throws {
        // 构造的流：finish_reason 已经到了，[DONE] 之前连接断开，回答是完整的
        let body = chunk("Hi") + chunk(nil, finishReason: "stop")
        #expect(try await collect(StubTransport(.truncated(body: Array(body.utf8), error: .network))) == ["Hi"])
    }

    @Test func disconnectBeforeFinishReasonIsNetworkError() async throws {
        await #expect(throws: ChatError.network) {
            try await collect(StubTransport(.truncated(body: Array(chunk("Hi").utf8), error: .network)))
        }
    }

    @Test func errorObjectInsideStreamIsProviderError() async throws {
        // 构造的流：OpenAI 兼容服务有时在流中途发一个 error 对象
        let body = chunk("Hi") + "data: {\"error\": {\"message\": \"boom\", \"type\": \"server_error\"}}\n\n"
        await #expect(throws: ChatError.providerError("boom")) {
            try await collect(StubTransport(body: body))
        }
    }

    @Test func unknownChunksAreIgnored() async throws {
        // 构造的流：宽松解码，看不懂的 chunk 跳过
        let body = "data: not json\n\n" + "data: {\"foo\": 1}\n\n" + chunk("Hi") + chunk(nil, finishReason: "stop")
        #expect(try await collect(StubTransport(body: body)) == ["Hi"])
    }

    @Test func transportNetworkErrorIsPassedThrough() async throws {
        await #expect(throws: ChatError.network) {
            try await collect(StubTransport(.failure(.network)))
        }
    }

    // MARK: 请求

    private func sentFields(
        _ connection: Connection,
        modelID: String = "deepseek-flash",
        jsonMode: Bool = false
    ) async throws -> [String: JSONValue] {
        let transport = StubTransport(body: chunk(nil, finishReason: "stop"))
        _ = try await collect(transport, connection: connection, modelID: modelID, jsonMode: jsonMode)
        let body = try JSONDecoder().decode(JSONValue.self, from: try #require(transport.requests.first?.body))
        guard case .object(let fields) = body else { Issue.record("body 不是对象"); return [:] }
        return fields
    }

    private func custom(_ baseURL: String, models: [ModelInfo] = []) -> Connection {
        Connection(name: "平台", baseURL: URL(string: baseURL)!, models: models)
    }

    @Test func deepSeekRequestDisablesThinkingAndSendsOnlySupportedFields() async throws {
        let transport = StubTransport(body: chunk(nil, finishReason: "stop"))
        _ = try await collect(transport, system: "简短回答", user: "1+1?")

        let sent = try #require(transport.requests.first)
        #expect(sent.method == "POST")
        #expect(sent.url.absoluteString == "https://api.deepseek.com/chat/completions")
        #expect(sent.headers["Authorization"] == "Bearer sk-test")
        #expect(sent.headers["Content-Type"] == "application/json")

        let body = try JSONDecoder().decode(JSONValue.self, from: try #require(sent.body))
        guard case .object(let fields) = body else { Issue.record("body 不是对象"); return }
        #expect(fields["model"] == .string("deepseek-flash"))
        #expect(fields["stream"] == .bool(true))
        #expect(fields["thinking"] == .object(["type": .string("disabled")]))
        for unsupported in ["n", "seed", "parallel_tool_calls", "max_completion_tokens", "logit_bias", "temperature", "tools"] {
            #expect(fields[unsupported] == nil, "不应该发送 \(unsupported)")
        }
        #expect(fields["messages"] == .array([
            .object(["role": .string("system"), "content": .string("简短回答")]),
            .object(["role": .string("user"), "content": .string("1+1?")]),
        ]))
    }

    @Test func emptySystemPromptIsOmitted() async throws {
        let fields = try await sentFields(connection)
        #expect(fields["messages"] == .array([
            .object(["role": .string("user"), "content": .string("Hi")]),
        ]))
    }

    @Test func otherOpenAICompatibleServicesDoNotGetThinkingField() async throws {
        let ollama = custom("http://localhost:11434/v1")
        let transport = StubTransport(body: chunk(nil, finishReason: "stop"))
        _ = try await collect(transport, connection: ollama)

        let sent = try #require(transport.requests.first)
        #expect(sent.url.absoluteString == "http://localhost:11434/v1/chat/completions")
        let body = try JSONDecoder().decode(JSONValue.self, from: try #require(sent.body))
        guard case .object(let fields) = body else { Issue.record("body 不是对象"); return }
        for field in ["thinking", "reasoning", "enable_thinking", "response_format"] {
            #expect(fields[field] == nil, "不应该发送 \(field)")
        }
    }

    // MARK: jsonMode

    @Test(arguments: [
        "https://api.deepseek.com",
        "https://openrouter.ai/api/v1",
    ])
    func jsonModeSendsResponseFormatOnDeepSeekAndOpenRouter(baseURL: String) async throws {
        let fields = try await sentFields(custom(baseURL), modelID: "deepseek/deepseek-v4.1-flash", jsonMode: true)
        #expect(fields["response_format"] == .object(["type": .string("json_object")]))
    }

    @Test(arguments: [
        "https://dashscope.aliyuncs.com/compatible-mode/v1",
        "http://localhost:11434/v1",
    ])
    func jsonModeIsNotSentOnOtherPlatforms(baseURL: String) async throws {
        let fields = try await sentFields(custom(baseURL), jsonMode: true)
        #expect(fields["response_format"] == nil)
    }

    @Test(arguments: ["https://api.deepseek.com", "https://openrouter.ai/api/v1"])
    func responseFormatIsNotSentWhenJsonModeIsOff(baseURL: String) async throws {
        let fields = try await sentFields(custom(baseURL), jsonMode: false)
        #expect(fields["response_format"] == nil)
    }

    // MARK: 按平台关闭思考（ADR-0003）

    @Test func openRouterRequestDisablesReasoning() async throws {
        let fields = try await sentFields(.openRouter(), modelID: "deepseek/deepseek-v4.1-flash")
        #expect(fields["reasoning"] == .object(["enabled": .bool(false)]))
        #expect(fields["thinking"] == nil)
        #expect(fields["enable_thinking"] == nil)
    }

    @Test func openRouterModelsThatMustReasonGetTheirLowestEffort() async throws {
        let models = try await OpenAICompatibleClient(transport: StubTransport(body: try Fixture.string("openrouter-models.json")))
            .listModels(connection: .openRouter(), apiKey: "sk-test")
        var openRouter = Connection.openRouter()
        openRouter.models = models

        #expect(try await sentFields(openRouter, modelID: "google/gemini-3.8-flash")["reasoning"]
            == .object(["effort": .string("low")]))
        #expect(try await sentFields(openRouter, modelID: "deepseek/deepseek-v4.1-flash")["reasoning"]
            == .object(["enabled": .bool(false)]))
    }

    @Test func openRouterModelsWithoutReasoningInfoOnlyDisableDeepSeek() async throws {
        // 没拉取过 Model 列表（手填的 Model ID）：缓存里没有 providerData
        var connection = Connection.openRouter()
        connection.models = [ModelInfo(id: "google/gemini-3.8-flash")]
        #expect(try await sentFields(connection, modelID: "deepseek/deepseek-v4.1-flash")["reasoning"]
            == .object(["enabled": .bool(false)]))
        #expect(try await sentFields(connection, modelID: "google/gemini-3.8-flash")["reasoning"] == nil)
        #expect(try await sentFields(.openRouter(), modelID: "google/gemini-3.8-flash")["reasoning"] == nil)
    }

    @Test func lowestEffortDoesNotDependOnListOrder() async throws {
        // 构造的 reasoning 对象：档位故意按从低到高排列
        let model = ModelInfo(
            id: "vendor/must-reason",
            providerData: .object(["reasoning": .object([
                "mandatory": .bool(true),
                "supported_efforts": .array([.string("medium"), .string("high"), .string("max")]),
            ])])
        )
        var connection = Connection.openRouter()
        connection.models = [model]
        #expect(try await sentFields(connection, modelID: "vendor/must-reason")["reasoning"]
            == .object(["effort": .string("medium")]))
    }

    @Test(arguments: [
        "https://dashscope.aliyuncs.com/compatible-mode/v1",
        "https://dashscope-intl.aliyuncs.com/compatible-mode/v1",
        "https://llm-abc123.cn-beijing.maas.aliyuncs.com/compatible-mode/v1",
    ])
    func bailianRequestDisablesThinking(baseURL: String) async throws {
        let fields = try await sentFields(custom(baseURL), modelID: "deepseek-v4-flash")
        #expect(fields["enable_thinking"] == .bool(false))
        #expect(fields["thinking"] == nil)
        #expect(fields["reasoning"] == nil)
    }

    @Test(arguments: ["deepseek-r1", "deepseek-r1-0528", "qwq-plus", "qvq-max", "qwen3-235b-a22b-thinking-2507"])
    func bailianThinkingOnlyModelsGetNoThinkingField(modelID: String) async throws {
        let fields = try await sentFields(.bailian(), modelID: modelID)
        #expect(fields["enable_thinking"] == nil)
    }

    @Test func platformIsRecognizedByHost() {
        #expect(Platform(host: "api.deepseek.com") == .deepSeek)
        #expect(Platform(host: "openrouter.ai") == .openRouter)
        #expect(Platform(host: "us.openrouter.ai") == .openRouter)
        #expect(Platform(host: "eu.openrouter.ai") == .openRouter)
        #expect(Platform(host: "dashscope.aliyuncs.com") == .bailian)
        #expect(Platform(host: "dashscope-intl.aliyuncs.com") == .bailian)
        #expect(Platform(host: "dashscope-us.aliyuncs.com") == .bailian)
        #expect(Platform(host: "cn-hongkong.dashscope.aliyuncs.com") == .bailian)
        #expect(Platform(host: "trial.cn-beijing.maas.aliyuncs.com") == .bailian)
        #expect(Platform(host: "LLM-X.AP-SOUTHEAST-1.MAAS.ALIYUNCS.COM") == .bailian)
        #expect(Platform(host: "oss-cn-beijing.aliyuncs.com") == nil)
        #expect(Platform(host: "notopenrouter.ai") == nil)
        #expect(Platform(host: "localhost") == nil)
        #expect(Platform(host: nil) == nil)
    }

    @Test func templatesPointAtTheirPlatforms() {
        #expect(Connection.deepSeek().platform == .deepSeek)
        #expect(Connection.openRouter().platform == .openRouter)
        #expect(Connection.bailian().platform == .bailian)
        #expect(Connection.custom(baseURL: URL(string: "http://localhost:11434/v1")!).platform == nil)
    }

    // MARK: 错误映射

    /// 错误体是构造的：DeepSeek 文档只有状态码表，没有错误体示例，这里按 OpenAI 的 `{"error": {...}}` 形状写。
    private static func errorBody(_ message: String, code: String? = nil) -> String {
        let codeJSON = code.map { ", \"code\": \"\($0)\"" } ?? ""
        return "{\"error\": {\"message\": \"\(message)\", \"type\": \"invalid_request_error\"\(codeJSON)}}"
    }

    @Test(arguments: [
        (401, [:], errorBody("Authentication Fails"), ChatError.authentication),
        (402, [:], errorBody("Insufficient Balance"), ChatError.rateLimited(retryAfter: nil)),
        (429, ["Retry-After": "7"], errorBody("Rate Limit Reached"), ChatError.rateLimited(retryAfter: 7)),
        (429, [:], errorBody("Rate Limit Reached"), ChatError.rateLimited(retryAfter: nil)),
        (400, [:], errorBody("Invalid Format"), ChatError.invalidRequest("Invalid Format")),
        (422, [:], errorBody("Invalid Parameters"), ChatError.invalidRequest("Invalid Parameters")),
        (400, [:], errorBody("This model's maximum context length is 1048576 tokens."), ChatError.contextTooLong),
        (400, [:], errorBody("too long", code: "context_length_exceeded"), ChatError.contextTooLong),
        (500, [:], errorBody("Server Error"), ChatError.overloaded),
        (503, [:], errorBody("Server Overloaded"), ChatError.overloaded),
        (418, [:], errorBody("teapot"), ChatError.providerError("teapot")),
        (418, [:], "plain text body", ChatError.providerError("plain text body")),
        (418, [:], "", ChatError.providerError("HTTP 418")),
    ] as [(Int, [String: String], String, ChatError)])
    func httpErrorsAreMapped(statusCode: Int, headers: [String: String], body: String, expected: ChatError) async throws {
        let transport = StubTransport(statusCode: statusCode, headers: headers, body: body)
        await #expect(throws: expected) {
            try await collect(transport)
        }
        await #expect(throws: expected) {
            try await OpenAICompatibleClient(transport: transport).listModels(connection: connection, apiKey: "sk-test")
        }
    }

    @Test func hugeErrorBodyIsTruncated() async throws {
        let transport = StubTransport(statusCode: 418, body: String(repeating: "x", count: 1_000_000))
        do {
            _ = try await collect(transport)
            Issue.record("应该抛错")
        } catch ChatError.providerError(let message) {
            #expect(message.count <= 2_000)
        }
    }

    // MARK: Model 列表

    @Test func listModelsReadsOfficialExample() async throws {
        let transport = StubTransport(body: try Fixture.string("deepseek-models.json"))
        let models = try await OpenAICompatibleClient(transport: transport).listModels(connection: connection, apiKey: "sk-test")

        #expect(models == [
            ModelInfo(id: "deepseek-flash", displayName: "DeepSeek-V4.1-Flash"),
            ModelInfo(id: "deepseek-v4-pro", displayName: "DeepSeek-V4-Pro"),
        ])
        let sent = try #require(transport.requests.first)
        #expect(sent.method == "GET")
        #expect(sent.url.absoluteString == "https://api.deepseek.com/models")
        #expect(sent.headers["Authorization"] == "Bearer sk-test")
    }

    @Test func listModelsKeepsOpenRouterReasoningInfo() async throws {
        let transport = StubTransport(body: try Fixture.string("openrouter-models.json"))
        let models = try await OpenAICompatibleClient(transport: transport).listModels(connection: .openRouter(), apiKey: "sk-test")
        let gemini = try #require(models.first { $0.id == "google/gemini-3.8-flash" })
        #expect(gemini.providerData?["reasoning"]?["mandatory"]?.boolValue == true)
    }

    @Test func listModelsWithoutExtraFieldsStillWorks() async throws {
        // 构造的响应：标准 OpenAI `/models` 只有 id
        let body = "{\"object\": \"list\", \"data\": [{\"id\": \"llama3\", \"object\": \"model\", \"owned_by\": \"library\"}]}"
        let models = try await OpenAICompatibleClient(transport: StubTransport(body: body)).listModels(connection: connection, apiKey: "")
        #expect(models == [ModelInfo(id: "llama3")])
    }

    @Test func unparsableModelListIsProviderError() async throws {
        await #expect(throws: ChatError.providerError("无法解析 Model 列表")) {
            try await OpenAICompatibleClient(transport: StubTransport(body: "<html>")).listModels(connection: connection, apiKey: "k")
        }
    }
}
