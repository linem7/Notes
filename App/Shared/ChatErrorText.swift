import Foundation
import NotesCore

extension ChatError {
    /// 模型调用出错时显示的说明（SPEC §4）。Quick Add 的 Draft 区和设置里保存 Connection 都用它；
    /// 各自的操作按钮（重试、打开设置）由使用方加。
    var displayText: String {
        switch self {
        case .authentication:
            String(localized: "The API key is invalid or has expired.")
        case .rateLimited(let retryAfter):
            if let retryAfter {
                String(localized: "Too many requests or out of quota. Try again in \(Int(retryAfter.rounded(.up))) seconds.")
            } else {
                String(localized: "Too many requests or out of quota.")
            }
        case .overloaded:
            String(localized: "The service is temporarily unavailable.")
        case .network:
            String(localized: "Network connection failed.")
        case .contextTooLong:
            String(localized: "The input is too long for this model. Remove some text or files and try again.")
        case .invalidRequest(let raw), .providerError(let raw):
            raw
        }
    }
}
