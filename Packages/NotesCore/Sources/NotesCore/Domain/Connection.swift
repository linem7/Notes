import Foundation

/// 用户配置的一条模型接入（CONTEXT.md）。v1 只有 OpenAI 兼容协议。
/// API key 不在这里：App 存在 Keychain，调用时传进来。
public struct Connection: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    /// 请求发到 `{baseURL}/chat/completions` 和 `{baseURL}/models`。
    /// DeepSeek 的 base URL 不带 `/v1`；OpenRouter、百炼、OpenAI 带。
    public var baseURL: URL
    /// 用户在设置里隐藏的 Model。
    public var hiddenModelIDs: Set<String>
    /// 上次拉取到的 Model 列表。
    public var models: [ModelInfo]

    public init(
        id: UUID = UUID(),
        name: String,
        baseURL: URL,
        hiddenModelIDs: Set<String> = [],
        models: [ModelInfo] = []
    ) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.hiddenModelIDs = hiddenModelIDs
        self.models = models
    }

    /// 这条 Connection 所在的平台；自己部署的服务和不认识的中转是 nil。
    public var platform: Platform? {
        Platform(host: baseURL.host)
    }

    // MARK: 模板

    public static func deepSeek(id: UUID = UUID(), name: String = "DeepSeek") -> Connection {
        Connection(id: id, name: name, baseURL: URL(string: "https://api.deepseek.com")!)
    }

    public static func openRouter(id: UUID = UUID(), name: String = "OpenRouter") -> Connection {
        Connection(id: id, name: name, baseURL: URL(string: "https://openrouter.ai/api/v1")!)
    }

    /// 默认北京地域；新加坡地域是 `https://dashscope-intl.aliyuncs.com/compatible-mode/v1`。
    public static func bailian(id: UUID = UUID(), name: String = "Alibaba Cloud Model Studio") -> Connection {
        Connection(id: id, name: name, baseURL: URL(string: "https://dashscope.aliyuncs.com/compatible-mode/v1")!)
    }

    /// Custom 模板：用户自填 base URL。
    public static func custom(id: UUID = UUID(), name: String = "Custom", baseURL: URL) -> Connection {
        Connection(id: id, name: name, baseURL: baseURL)
    }
}

/// 某个 Connection 下的一个 Model。
public struct ModelInfo: Codable, Sendable, Hashable, Identifiable {
    /// API 里的模型 ID，例如 `deepseek-flash`。
    public var id: String
    public var displayName: String?
    /// 接口报告的原文，只由 `OpenAICompatibleClient` 读取：OpenRouter 的 `reasoning` 对象
    /// （`mandatory`、`supported_efforts`），关闭思考时用（ADR-0003）。
    public var providerData: JSONValue?

    public init(id: String, displayName: String? = nil, providerData: JSONValue? = nil) {
        self.id = id
        self.displayName = displayName
        self.providerData = providerData
    }
}
