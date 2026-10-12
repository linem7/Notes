import Foundation

/// 提供模型 API 的平台，按 Connection 的 base URL 的 host 识别（CONTEXT.md）。
/// 平台决定关闭思考等非标准字段怎么发（ADR-0003）。
public enum Platform: Sendable, Hashable {
    /// DeepSeek 官方：`api.deepseek.com`
    case deepSeek
    /// OpenRouter：`openrouter.ai`，以及地域端点 `us.openrouter.ai`、`eu.openrouter.ai`
    case openRouter
    /// 阿里云百炼（DashScope）：`dashscope.aliyuncs.com`、`dashscope-intl.aliyuncs.com`、
    /// `cn-hongkong.dashscope.aliyuncs.com`、业务空间专属域名 `{WorkspaceId}.{region}.maas.aliyuncs.com` 等。
    case bailian

    /// 不认识的 host 返回 nil：按标准 OpenAI 兼容接口处理，不发任何非标准字段。
    public init?(host: String?) {
        guard let host = host?.lowercased() else { return nil }
        func matches(_ domain: String) -> Bool { host == domain || host.hasSuffix(".\(domain)") }

        if matches("deepseek.com") {
            self = .deepSeek
        } else if matches("openrouter.ai") {
            self = .openRouter
        } else if host.hasSuffix(".aliyuncs.com"),
                  host.hasPrefix("dashscope") || matches("dashscope.aliyuncs.com") || matches("maas.aliyuncs.com") {
            self = .bailian
        } else {
            return nil
        }
    }
}
