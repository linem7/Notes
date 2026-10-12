import Foundation
import Testing
@testable import NotesCore

/// 请求的 URL 和头、HTTP 错误映射的边界、流解码的边界。流和错误体都是按协议描述自己构造的，不是官方原文。
struct OpenAICompatibleClientRequestTests {
    private let connection = Connection.deepSeek()

    private func chunk(_ content: String?, index: Int = 0, finishReason: String? = nil) -> String {
        let contentJSON = content.map { "\"content\": \"\($0)\"" } ?? "\"content\": null"
        let finishJSON = finishReason.map { "\"\($0)\"" } ?? "null"
        return "data: {\"choices\": [{\"index\": \(index), \"delta\": {\(contentJSON)}, \"finish_reason\": \(finishJSON)}]}\n\n"
    }

    private func collect(_ transport: StubTransport, connection: Connection? = nil) async throws -> [String] {
        let client = OpenAICompatibleClient(transport: transport)
        var fragments: [String] = []
        let stream = client.complete(
            system: "", user: "Hi", modelID: "m", connection: connection ?? self.connection, apiKey: "sk-test", jsonMode: false
        )
        for try await fragment in stream { fragments.append(fragment) }
        return fragments
    }

    // MARK: 取消

    @Test func cancellingNeverSurfacesAnythingButCancellationOrAPlainEnd() async throws {
        let transport = HangingTransport()
        let client = OpenAICompatibleClient(transport: transport)
        let connection = self.connection
        let consumer = Task { () -> (any Error)? in
            let stream = client.complete(
                system: "", user: "Hi", modelID: "m", connection: connection, apiKey: "sk-test", jsonMode: false
            )
            do {
                for try await _ in stream {}
                return nil
            } catch {
                return error
            }
        }
        try await transport.waitUntil { transport.bodyIsOpen }
        consumer.cancel()
        let error = await consumer.value
        #expect(!(error is ChatError), "取消后不应收到 ChatError：\(String(describing: error))")
        #expect(error == nil || error is CancellationError)
        try await transport.waitUntil { transport.bodyWasCancelled }
    }

    // MARK: URL 和请求头

    @Test(arguments: [
        ("https://api.deepseek.com", "https://api.deepseek.com/chat/completions", "https://api.deepseek.com/models"),
        ("https://openrouter.ai/api/v1", "https://openrouter.ai/api/v1/chat/completions", "https://openrouter.ai/api/v1/models"),
        ("https://example.com/v1/", "https://example.com/v1/chat/completions", "https://example.com/v1/models"),
        ("http://localhost:11434/v1", "http://localhost:11434/v1/chat/completions", "http://localhost:11434/v1/models"),
    ])
    func endpointsAreAppendedToTheBaseURL(base: String, chat: String, models: String) async throws {
        let connection = Connection.custom(baseURL: URL(string: base)!)

        let chatTransport = StubTransport(body: chunk(nil, finishReason: "stop"))
        _ = try await collect(chatTransport, connection: connection)
        #expect(chatTransport.requests.first?.url.absoluteString == chat)

        let modelsTransport = StubTransport(body: "{\"data\": []}")
        _ = try await OpenAICompatibleClient(transport: modelsTransport).listModels(connection: connection, apiKey: "k")
        #expect(modelsTransport.requests.first?.url.absoluteString == models)
    }

    @Test func completionRequestIsAStreamingJSONPostWithBearerKey() async throws {
        let transport = StubTransport(body: chunk(nil, finishReason: "stop"))
        _ = try await collect(transport)
        let sent = try #require(transport.requests.first)
        #expect(sent.method == "POST")
        #expect(sent.headers["Authorization"] == "Bearer sk-test")
        #expect(sent.headers["Content-Type"] == "application/json")
        #expect(sent.headers["Accept"] == "text/event-stream")
    }

    // MARK: HTTP 错误映射的边界

    @Test(arguments: [
        // 数字 code 不是 context_length_exceeded，按状态码走
        (400, [:], "{\"error\": {\"message\": \"bad\", \"code\": 400}}", ChatError.invalidRequest("bad")),
        // Retry-After 是 HTTP 日期时读不出秒数
        (429, ["Retry-After": "Wed, 21 Oct 2026 07:28:00 GMT"], "{}", ChatError.rateLimited(retryAfter: nil)),
        // 两侧空白照常读
        (429, ["Retry-After": " 7 "], "{}", ChatError.rateLimited(retryAfter: 7)),
        // 网关的 HTML 页：5xx 按状态码，其他状态码原样（截断后）显示
        (502, [:], "<html>Bad Gateway</html>", ChatError.overloaded),
        (404, [:], "<html>Not Found</html>", ChatError.providerError("<html>Not Found</html>")),
        // 空白 body 等同于空
        (404, [:], "  \n", ChatError.providerError("HTTP 404")),
        // 401 优先于 body 内容
        (401, [:], "<html></html>", ChatError.authentication),
    ] as [(Int, [String: String], String, ChatError)])
    func httpErrorEdgeCases(statusCode: Int, headers: [String: String], body: String, expected: ChatError) async throws {
        let transport = StubTransport(statusCode: statusCode, headers: headers, body: body)
        await #expect(throws: expected) {
            try await collect(transport)
        }
    }

    // MARK: 流解码的边界

    @Test func emptyNullAndEmptyChoiceChunksProduceNoFragments() async throws {
        let body = chunk("") + chunk(nil)
            + "data: {\"choices\": []}\n\n"                       // 只带 usage 的收尾 chunk
            + "data: {\"choices\": [{\"index\": 0, \"delta\": {}}]}\n\n"
            + chunk("Hi") + chunk(nil, finishReason: "stop")
        #expect(try await collect(StubTransport(body: body)) == ["Hi"])
    }

    @Test func onlyChoiceZeroIsRead() async throws {
        let body = chunk("A", index: 1) + chunk("Hi", index: 0) + chunk("B", index: 1) + chunk(nil, finishReason: "stop")
        #expect(try await collect(StubTransport(body: body)) == ["Hi"])
    }

    @Test func multiByteCharactersSurviveByteByByteDelivery() async throws {
        // StubTransport 一个字节一个字节地交 body，多字节字符会被拆开
        let body = chunk("你好🙂") + chunk("，世界") + chunk(nil, finishReason: "stop")
        #expect(try await collect(StubTransport(body: body)) == ["你好🙂", "，世界"])
    }
}
