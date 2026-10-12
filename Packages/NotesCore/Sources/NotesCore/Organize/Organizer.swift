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

/// 交给 Organize 的一个 Material：Quick Add 里的 `StagedMaterial` 加它的 Readable Text 准备结果（`MaterialIntake.prepare`）。
public struct OrganizeMaterial: Hashable, Sendable {
    public var staged: StagedMaterial
    public var prepared: PreparedText

    public init(staged: StagedMaterial, prepared: PreparedText) {
        self.staged = staged
        self.prepared = prepared
    }

    /// 发给模型的 Readable Text；还没准备好、拿不到、或者只有空白的是 nil（模型只看到名字）。
    var readableText: String? {
        guard case .ready(let text) = prepared.state, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }
}

/// Organize：把 Quick Add 的输入（原文 + 各 Material 的 Readable Text）交给模型，得到 Draft（CONTEXT.md）。
public struct Organizer: Sendable {
    private let client: any OrganizeModelClient

    public init(client: any OrganizeModelClient = OpenAICompatibleClient()) {
        self.client = client
    }

    /// 调一次模型，收齐全文再解析。出错抛 `ChatError`（模型调用失败）；JSON 解析失败不报错，返回 fallback Draft。
    /// 取消调用方的 Task 会取消请求并抛 `CancellationError`。
    ///
    /// 这个版本直接收 Quick Add 的 Material：按 `budget`（ARCHITECTURE §4.1）截断原文和每个 Readable Text
    /// （存储里的原文不动），再拼成 prompt。Draft 的 `materialIndices` 指向 `materials` 数组（从 0 开始）。
    ///
    /// - Parameters:
    ///   - input: 用户在 Quick Add 里输入的原文。
    ///   - materials: 各 Material 和它们的 Readable Text 准备结果，调用方应该已经等完 pending 的（或把超时的当 unavailable）。
    ///   - budget: 发给模型的字数上限。
    ///   - userPrompt: 用户可编辑的 Organize prompt，默认 `OrganizePrompt.default`。
    ///   - onProgress: 每收到一段正文就调用一次，参数是目前收到的字符数。
    public func organize(
        input: String,
        materials: [OrganizeMaterial],
        budget: MaterialBudget = .default,
        connection: Connection,
        modelID: String,
        apiKey: String,
        userPrompt: String = OrganizePrompt.default,
        now: Date = Date(),
        timeZone: TimeZone = .current,
        onProgress: (@Sendable (Int) -> Void)? = nil
    ) async throws -> [Draft] {
        let budgeted = budget.apply(source: input, materialTexts: materials.map(\.readableText))
        let promptMaterials = zip(materials, budgeted.materials).map { material, text in
            Self.promptMaterial(material, text: text)
        }
        return try await run(
            promptInput: budgeted.source, fallbackInput: input, promptMaterials: promptMaterials,
            connection: connection, modelID: modelID, apiKey: apiKey,
            userPrompt: userPrompt, now: now, timeZone: timeZone, onProgress: onProgress
        )
    }

    static func promptMaterial(_ material: OrganizeMaterial, text: String?) -> PromptMaterial {
        switch material.staged.kind {
        case .webPage:
            return PromptMaterial(
                kind: .webPage, name: material.prepared.title ?? material.staged.displayName,
                url: material.staged.url?.absoluteString, title: material.prepared.title, text: text
            )
        case .file, .source:
            return PromptMaterial(kind: .file, name: material.staged.displayName, text: text)
        }
    }

    /// 底层版本：`promptMaterials` 已经按 `MaterialBudget` 截断过，`input` 原样发出。
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
        try await run(
            promptInput: input, fallbackInput: input, promptMaterials: materials,
            connection: connection, modelID: modelID, apiKey: apiKey,
            userPrompt: userPrompt, now: now, timeZone: timeZone, onProgress: onProgress
        )
    }

    private func run(
        promptInput: String,
        fallbackInput: String,
        promptMaterials materials: [PromptMaterial],
        connection: Connection,
        modelID: String,
        apiKey: String,
        userPrompt: String,
        now: Date,
        timeZone: TimeZone,
        onProgress: (@Sendable (Int) -> Void)?
    ) async throws -> [Draft] {
        let stream = client.complete(
            system: OrganizePrompt.system(now: now, timeZone: timeZone, prompt: userPrompt),
            user: OrganizePrompt.userMessage(input: promptInput, materials: materials),
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
        // fallback 的 Title 用用户原文的第一行，不用被截断的
        return OrganizeResponseParser.parse(text, input: fallbackInput, materialNames: materials.map(\.name))
    }
}
