import Foundation

/// `Organizer` 需要的模型调用，方便测试时换成假的。`OpenAICompatibleClient` 直接满足它。
public protocol OrganizeModelClient: Sendable {
    func complete(
        system: String,
        user: String,
        modelID: String,
        connection: Connection,
        apiKey: String,
        jsonMode: Bool
    ) -> AsyncThrowingStream<String, any Error>
}

extension OpenAICompatibleClient: OrganizeModelClient {}

/// Organize：把 Quick Add 的输入（原文 + 各 Material 的 Readable Text）交给模型，得到 Draft（CONTEXT.md）。
public struct Organizer: Sendable {
    private let client: any OrganizeModelClient

    public init(client: any OrganizeModelClient = OpenAICompatibleClient()) {
        self.client = client
    }

    /// 调一次模型，收齐全文再解析。出错抛 `ChatError`（模型调用失败）；JSON 解析失败不报错，返回 fallback Draft。
    /// 取消调用方的 Task 会取消请求并抛 `CancellationError`。
    ///
    /// - Parameters:
    ///   - input: 用户在 Quick Add 里输入的原文。
    ///   - materials: 已按 `MaterialBudget` 截断的 Material；Draft 的 `materialIndices` 指向这个数组。
    ///   - userPrompt: 用户可编辑的 Organize prompt，默认 `OrganizePrompt.default`。
    ///   - onProgress: 每收到一段正文就调用一次，参数是目前收到的字符数。
    public func organize(
        input: String,
        promptMaterials materials: [PromptMaterial],
        connection: Connection,
        modelID: String,
        apiKey: String,
        userPrompt: String = OrganizePrompt.default,
        now: Date = Date(),
        timeZone: TimeZone = .current,
        onProgress: (@Sendable (Int) -> Void)? = nil
    ) async throws -> [Draft] {
        let stream = client.complete(
            system: OrganizePrompt.system(now: now, timeZone: timeZone, prompt: userPrompt),
            user: OrganizePrompt.userMessage(input: input, materials: materials),
            modelID: modelID,
            connection: connection,
            apiKey: apiKey,
            jsonMode: true
        )
        var text = ""
        var received = 0
        for try await fragment in stream {
            text += fragment
            received += fragment.count
            onProgress?(received)
        }
        try Task.checkCancellation()
        return OrganizeResponseParser.parse(text, input: input, materialNames: materials.map(\.name))
    }
}
