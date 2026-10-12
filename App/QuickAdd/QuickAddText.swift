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
    /// key 无效时除了重试还给「打开设置」（改好 key 之后回来可以直接重试）。
    var offersOpenSettings: Bool {
        if case .authentication = self { return true }
        return false
    }
}
