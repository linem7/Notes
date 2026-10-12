import Foundation
import NotesCore

extension UnavailableReason {
    /// Material 块上警告标记的悬停说明（SPEC §3.2）。
    var hoverText: String {
        switch self {
        case .notReadable: String(localized: "This file type can't be read. It is saved, and the model only sees its name.")
        case .unreadableFile: String(localized: "Couldn't read this file.")
        case .passwordProtected: String(localized: "This PDF is password-protected.")
        case .noTextRecognized: String(localized: "No text was recognized.")
        case .pageLoadFailed: String(localized: "Couldn't load the page.")
        case .pageHasNoText: String(localized: "The page has no readable text.")
        case .cancelled: String(localized: "Preparing the text was cancelled.")
        }
    }
}

extension ChatError {
    /// 显示在 Draft 区的错误说明（SPEC §4）。
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

    /// key 无效时除了重试还给「打开设置」（改好 key 之后回来可以直接重试）。
    var offersOpenSettings: Bool {
        if case .authentication = self { return true }
        return false
    }
}
