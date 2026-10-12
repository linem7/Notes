import Foundation

/// 界面语言（SPEC §6）：默认英文，不跟随系统；设置里可选简体中文。
/// 切换写 `AppleLanguages`，重启后生效。
public enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    public var id: String { rawValue }

    private static let appleLanguagesKey = "AppleLanguages"
    private static let didSetInitialKey = "didSetInitialLanguage"

    /// 首次启动：把 `AppleLanguages` 设为英文，只做一次。返回这次是否写了。
    @discardableResult
    public static func applyInitialDefault(in defaults: UserDefaults = .standard) -> Bool {
        guard !defaults.bool(forKey: didSetInitialKey) else { return false }
        defaults.set([english.rawValue], forKey: appleLanguagesKey)
        defaults.set(true, forKey: didSetInitialKey)
        return true
    }

    public func select(in defaults: UserDefaults = .standard) {
        defaults.set([rawValue], forKey: Self.appleLanguagesKey)
        defaults.set(true, forKey: Self.didSetInitialKey)
    }

    /// 当前写在 defaults 里的语言（下次启动生效的那个）。
    public static func stored(in defaults: UserDefaults = .standard) -> AppLanguage {
        let first = (defaults.array(forKey: appleLanguagesKey) as? [String])?.first ?? ""
        return first.hasPrefix("zh") ? .simplifiedChinese : .english
    }
}
