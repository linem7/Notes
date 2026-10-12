import Foundation

/// 用户改过的 Organize prompt（SPEC §4、§7），存在 UserDefaults。
/// 默认文本是 `OrganizePrompt.default`，由调用方传入；当前日期等不在可编辑文本里（发送时加在最前面）。
public enum OrganizePromptSetting {
    public static let defaultsKey = "organizePrompt"

    /// 用户的文本；没改过（或存的是空白）时是默认文本。
    public static func text(defaultText: String, in defaults: UserDefaults = .standard) -> String {
        guard let stored = defaults.string(forKey: defaultsKey),
              !stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return defaultText }
        return stored
    }

    public static func restoreDefault(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: defaultsKey)
    }
}
