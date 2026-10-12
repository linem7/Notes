import Foundation
import Testing
@testable import NotesCore

struct OrganizePromptSettingTests {
    private func defaults() -> UserDefaults {
        let name = "OrganizePromptSettingTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func unchangedPromptIsTheDefault() {
        #expect(OrganizePromptSetting.text(defaultText: "default", in: defaults()) == "default")
    }

    @Test func editedPromptWinsAndRestoreBringsDefaultBack() {
        let defaults = defaults()
        defaults.set("mine", forKey: OrganizePromptSetting.defaultsKey)
        #expect(OrganizePromptSetting.text(defaultText: "default", in: defaults) == "mine")
        OrganizePromptSetting.restoreDefault(in: defaults)
        #expect(OrganizePromptSetting.text(defaultText: "default", in: defaults) == "default")
    }

    @Test func blankPromptFallsBackToDefault() {
        let defaults = defaults()
        defaults.set("  \n ", forKey: OrganizePromptSetting.defaultsKey)
        #expect(OrganizePromptSetting.text(defaultText: "default", in: defaults) == "default")
    }
}
