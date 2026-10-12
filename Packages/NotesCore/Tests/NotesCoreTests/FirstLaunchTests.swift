import Foundation
import Testing
@testable import NotesCore

struct FirstLaunchTests {
    @Test func onlyTheFirstLaunchIsFirst() {
        let name = "FirstLaunchTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        #expect(FirstLaunch(defaults: defaults).isFirstLaunch)
        #expect(!FirstLaunch(defaults: defaults).isFirstLaunch)
    }
}
