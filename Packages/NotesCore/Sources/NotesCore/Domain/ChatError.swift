import Foundation

/// 模型调用出错的类别（SPEC §4）。`OpenAICompatibleClient` 把 HTTP 状态码、错误体和流中的错误事件
/// 映射到这里：它抛出的错误（`listModels` 和 `complete` 的流）一律是 ChatError；
/// 用户取消抛 `CancellationError`，不属于错误，调用方不要显示。
public enum ChatError: Error, Codable, Sendable, Hashable {
    /// key 无效或缺失。
    case authentication
    /// 限流或额度用完。接口给了等待时间（秒）时带上。
    case rateLimited(retryAfter: TimeInterval?)
    /// 服务端过载、5xx。
    case overloaded
    /// 断网、超时。
    case network
    /// 输入太长，超出了模型的上下文。
    case contextTooLong
    /// 请求无效，带接口返回的原始信息。
    case invalidRequest(String)
    /// 其他接口侧错误，带接口返回的原始信息。
    case providerError(String)
}
