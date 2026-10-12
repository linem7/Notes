import Foundation

/// OpenAI 兼容协议的客户端（ARCHITECTURE §4.2）：一次 system + user 的流式调用，加上 `/models` 拉取。
///
/// - 端点是 `POST {base}/chat/completions` 和 `GET {base}/models`，DeepSeek 的 base URL 不带 `/v1`。
/// - 按平台关闭思考（ADR-0003，平台见 `Platform`）：DeepSeek 发 `thinking: {type: "disabled"}`，
///   OpenRouter 发 `reasoning: {enabled: false}`（关不掉的模型发最低档 effort），
///   百炼发 `enable_thinking: false`；其他服务什么都不发。
/// - `jsonMode` 为 true 且平台是 DeepSeek 或 OpenRouter 时发 `response_format: {"type": "json_object"}`；
///   其他平台不发，靠 prompt 约束。
/// - 不发 `temperature`；也不发 DeepSeek 不支持的 OpenAI 字段（`n`、`seed`、`parallel_tool_calls`、
///   `max_completion_tokens`、`logit_bias`），不用 `developer` role。
/// - 错误：抛出的一律是 `ChatError`；取消抛 `CancellationError`。
public struct OpenAICompatibleClient: Sendable {
    private let transport: any HTTPTransport

    public init(transport: any HTTPTransport = defaultHTTPTransport()) {
        self.transport = transport
    }

    /// 拉取 Model 列表；保存 Connection 时也用它做连接测试。抛出 `ChatError`。
    public func listModels(connection: Connection, apiKey: String) async throws -> [ModelInfo] {
        do {
            let request = HTTPRequest(
                method: "GET",
                url: connection.baseURL.appendingPathComponent("models"),
                headers: ["Authorization": "Bearer \(apiKey)"]
            )
            let response = try await transport.send(request)
            try await Self.throwIfNotSuccess(response)
            let data = try await response.collectBody(limit: Self.modelListLimit)
            guard let list = try? JSONDecoder().decode(ModelList.self, from: data) else {
                throw ChatError.providerError("Couldn't parse the model list")
            }
            return list.data.map { $0.modelInfo }
        } catch {
            throw Self.normalize(error)
        }
    }

    /// 一次模型调用，流式返回正文片段，调用方自己拼成全文。出错时流以 `ChatError` 结束；
    /// 取消调用方的 Task（或停止迭代）会取消请求，流以 `CancellationError` 结束。
    public func complete(
        system: String,
        user: String,
        modelID: String,
        connection: Connection,
        apiKey: String,
        jsonMode: Bool
    ) -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try Self.httpRequest(
                        system: system, user: user, modelID: modelID,
                        connection: connection, apiKey: apiKey, jsonMode: jsonMode
                    )
                    try await run(request, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.normalize(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: 一次模型调用

    private func run(_ request: HTTPRequest, continuation: AsyncThrowingStream<String, any Error>.Continuation) async throws {
        let response = try await transport.send(request)
        try await Self.throwIfNotSuccess(response)

        var finished = false
        var sawDone = false
        do {
            for try await event in response.body.sseEvents() {
                if event.data == "[DONE]" {
                    sawDone = true
                    break
                }
                // 宽松解码：看不懂的 chunk 直接跳过
                guard let chunk = try? JSONDecoder().decode(StreamChunk.self, from: Data(event.data.utf8)) else { continue }
                if let error = chunk.error {
                    throw ChatError.providerError(error.message ?? event.data)
                }
                guard let choice = chunk.choices?.first(where: { ($0.index ?? 0) == 0 }) else { continue }
                if let content = choice.delta?.content, !content.isEmpty {
                    continuation.yield(content)
                }
                if let raw = choice.finishReason {
                    try Self.checkFinishReason(raw)
                    finished = true
                }
            }
        } catch where finished && !(error is CancellationError) {
            // finish_reason 已经到了，之后（[DONE] 之前）连接断开：回答是完整的，按正常结束处理
        }
        try Task.checkCancellation()

        // 没有 finish_reason 也没有 [DONE]：连接在中途断了
        if !finished && !sawDone { throw ChatError.network }
    }

    /// `stop`、`length` 等都算正常结束（`length` 截断的 JSON 由解析器兜底）；服务端中止和内容过滤是错误。
    private static func checkFinishReason(_ raw: String) throws {
        switch raw {
        case "insufficient_system_resource": throw ChatError.overloaded
        case "aborted": throw ChatError.providerError("The provider stopped generating (finish_reason: aborted)")
        case "content_filter": throw ChatError.providerError("The response was blocked by a content filter (finish_reason: content_filter)")
        default: break
        }
    }

    // MARK: 请求编码

    static func httpRequest(
        system: String,
        user: String,
        modelID: String,
        connection: Connection,
        apiKey: String,
        jsonMode: Bool
    ) throws -> HTTPRequest {
        var messages: [ChatMessage] = []
        if !system.isEmpty { messages.append(ChatMessage(role: "system", content: system)) }
        messages.append(ChatMessage(role: "user", content: user))

        var body = ChatRequestBody(model: modelID, messages: messages, stream: true)
        let platform = connection.platform
        switch platform {
        case .deepSeek:
            body.thinking = .init(type: "disabled")
        case .openRouter:
            body.reasoning = openRouterReasoning(modelID: modelID, connection: connection)
        case .bailian:
            body.enableThinking = isBailianThinkingOnly(modelID) ? nil : false
        case nil:
            break
        }
        if jsonMode, platform == .deepSeek || platform == .openRouter {
            body.responseFormat = .init(type: "json_object")
        }
        return HTTPRequest(
            method: "POST",
            url: connection.baseURL.appendingPathComponent("chat/completions"),
            headers: [
                "Authorization": "Bearer \(apiKey)",
                "Content-Type": "application/json",
                "Accept": "text/event-stream",
            ],
            body: try JSONEncoder().encode(body)
        )
    }

    /// 百炼里只会思考的模型（deepseek-r1、QwQ、QVQ、*-thinking）不接受关闭，发了可能报错。
    private static func isBailianThinkingOnly(_ modelID: String) -> Bool {
        let id = modelID.lowercased()
        return ["deepseek-r1", "qwq", "qvq"].contains { id.hasPrefix($0) } || id.contains("thinking")
    }

    /// OpenRouter 的统一 `reasoning` 参数，按 `/models` 报告的 `reasoning` 对象（存在 providerData 里）决定：
    /// - `mandatory` 的模型关不掉思考，发 `enabled: false` 会被拒绝，改发它支持的最低档 effort；没有档位可选就什么都不发。
    /// - 其他模型发 `enabled: false`。
    /// - 没有 `reasoning` 信息（没拉取过 Model 列表、手填的 Model ID，或者这个模型不会思考）：只给 DeepSeek 发
    ///   `enabled: false`（OpenRouter 上的 DeepSeek 都能关），其他模型什么都不发，免得关不掉思考的模型被拒。
    private static func openRouterReasoning(modelID: String, connection: Connection) -> ChatRequestBody.Reasoning? {
        guard let reasoning = connection.models.first(where: { $0.id == modelID })?.providerData?["reasoning"] else {
            return modelID.lowercased().hasPrefix("deepseek/") ? .init(enabled: false) : nil
        }
        guard reasoning["mandatory"]?.boolValue == true else { return .init(enabled: false) }
        guard case .array(let efforts)? = reasoning["supported_efforts"] else { return nil }
        let supported = Set(efforts.compactMap(\.stringValue))
        return effortsFromLowest.first(where: supported.contains).map { .init(effort: $0) }
    }

    /// OpenRouter 的 effort 档位，从低到高（`none` 是关闭，关不掉思考的模型不接受）。接口没有承诺 `supported_efforts` 的顺序。
    private static let effortsFromLowest = ["minimal", "low", "medium", "high", "xhigh", "max"]

    // MARK: 错误映射

    /// 错误体只读这么多字节。
    static let errorBodyLimit = 64 * 1024
    /// 显示给用户的原始错误信息最多这么多字符。
    static let errorMessageLimit = 2_000
    static let modelListLimit = 4 * 1024 * 1024

    private static func throwIfNotSuccess(_ response: HTTPResponse) async throws {
        guard !(200..<300).contains(response.statusCode) else { return }
        let data = try await response.collectBody(limit: errorBodyLimit)
        throw chatError(statusCode: response.statusCode, headers: response.headers, body: data)
    }

    static func chatError(statusCode: Int, headers: [String: String], body: Data) -> ChatError {
        let detail = try? JSONDecoder().decode(ErrorEnvelope.self, from: body).error
        let rawText = String(decoding: body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        var message = detail?.message ?? (rawText.isEmpty ? "HTTP \(statusCode)" : rawText)
        if message.count > errorMessageLimit { message = String(message.prefix(errorMessageLimit)) }

        // 启发式判断：DeepSeek 文档没写上下文超长时返回什么，这里按 OpenAI 的惯例
        // （code 是 context_length_exceeded，或者 message 里有 "maximum context length"）识别。
        // 还没有用真实 key 验证过。
        if statusCode == 400,
           detail?.code?.stringValue == "context_length_exceeded"
            || message.localizedCaseInsensitiveContains("maximum context length") {
            return .contextTooLong
        }

        switch statusCode {
        case 401: return .authentication
        // 402 是 DeepSeek 的余额不足；SPEC §4 把「额度用完」归到 rateLimited
        case 402: return .rateLimited(retryAfter: nil)
        case 429: return .rateLimited(retryAfter: headers["retry-after"].flatMap { TimeInterval($0.trimmingCharacters(in: .whitespaces)) })
        case 400, 422: return .invalidRequest(message)
        case 500..<600: return .overloaded
        default: return .providerError(message)
        }
    }

    /// 把其他错误统一成 ChatError；取消原样往外传。
    private static func normalize(_ error: any Error) -> any Error {
        if error is ChatError || error is CancellationError { return error }
        if Task.isCancelled { return CancellationError() }
        return ChatError.providerError(String(describing: error))
    }
}

// MARK: - 线上格式

private struct ChatRequestBody: Encodable {
    struct Thinking: Encodable { var type: String }
    struct Reasoning: Encodable {
        var enabled: Bool?
        var effort: String?
    }
    struct ResponseFormat: Encodable { var type: String }

    var model: String
    var messages: [ChatMessage]
    var stream: Bool
    /// DeepSeek 官方
    var thinking: Thinking?
    /// OpenRouter
    var reasoning: Reasoning?
    /// 百炼
    var enableThinking: Bool?
    var responseFormat: ResponseFormat?

    enum CodingKeys: String, CodingKey {
        case model, messages, stream, thinking, reasoning
        case enableThinking = "enable_thinking"
        case responseFormat = "response_format"
    }
}

private struct ChatMessage: Encodable {
    var role: String
    var content: String
}

private struct StreamChunk: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable {
            var content: String?
        }
        var index: Int?
        var delta: Delta?
        var finishReason: String?

        enum CodingKeys: String, CodingKey {
            case index, delta
            case finishReason = "finish_reason"
        }
    }

    var choices: [Choice]?
    var error: ErrorDetail?
}

private struct ErrorEnvelope: Decodable {
    var error: ErrorDetail
}

private struct ErrorDetail: Decodable {
    var message: String?
    var type: String?
    /// 有的服务是字符串，有的是数字
    var code: JSONValue?
}

private struct ModelList: Decodable {
    struct Entry: Decodable {
        var id: String
        var name: String?
        /// OpenRouter 报告的思考选项（`mandatory`、`supported_efforts` 等），存进 providerData，关闭思考时用
        var reasoning: JSONValue?

        var modelInfo: ModelInfo {
            let providerData: JSONValue? = reasoning.flatMap { $0 == .null ? nil : .object(["reasoning": $0]) }
            return ModelInfo(id: id, displayName: name, providerData: providerData)
        }
    }

    var data: [Entry]
}
