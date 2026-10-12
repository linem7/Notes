import Foundation
import Testing
@testable import NotesCore

struct AppLanguageTests {
    private func defaults() -> UserDefaults {
        let name = "AppLanguageTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func firstLaunchSetsEnglishOnce() {
        let defaults = defaults()
        #expect(defaults.object(forKey: "didSetInitialLanguage") == nil)
        #expect(AppLanguage.applyInitialDefault(in: defaults))
        #expect(defaults.array(forKey: "AppleLanguages") as? [String] == ["en"])
        #expect(defaults.bool(forKey: "didSetInitialLanguage"))

        // 用户之后选了中文，再次启动不能被改回英文
        AppLanguage.simplifiedChinese.select(in: defaults)
        #expect(!AppLanguage.applyInitialDefault(in: defaults))
        #expect(AppLanguage.stored(in: defaults) == .simplifiedChinese)
    }

    @Test func selectingWritesAppleLanguages() {
        let defaults = defaults()
        AppLanguage.simplifiedChinese.select(in: defaults)
        #expect(defaults.array(forKey: "AppleLanguages") as? [String] == ["zh-Hans"])
        // 选过语言就不再算「首次」，下次启动不会被改回英文
        #expect(defaults.bool(forKey: "didSetInitialLanguage"))
        AppLanguage.english.select(in: defaults)
        #expect(defaults.array(forKey: "AppleLanguages") as? [String] == ["en"])
        #expect(AppLanguage.stored(in: defaults) == .english)
    }

    @Test func storedTreatsAnyChineseAsSimplifiedChinese() {
        let defaults = defaults()
        defaults.set(["zh-Hans-CN", "en"], forKey: "AppleLanguages")
        #expect(AppLanguage.stored(in: defaults) == .simplifiedChinese)
    }
}
