import Foundation
import Testing
@testable import NotesCore

@MainActor
struct ConnectionStoreTests {
    private func defaults() -> UserDefaults {
        let name = "ConnectionStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func deepSeek(models: [String] = ["deepseek-flash", "deepseek-pro"]) -> Connection {
        var connection = Connection.deepSeek()
        connection.models = models.map { ModelInfo(id: $0) }
        return connection
    }

    @Test func firstSavedConnectionBecomesDefaultModel() {
        let store = ConnectionStore(defaults: defaults())
        let connection = deepSeek()
        store.save(connection)
        #expect(store.defaultModel == ModelRef(connectionID: connection.id, modelID: "deepseek-flash"))
        // 已经有 Default Model 时，保存别的 Connection 不改它
        store.save(.openRouter())
        #expect(store.defaultModel?.connectionID == connection.id)
    }

    @Test func deepSeekPrefersFlashWhateverTheListOrder() {
        let store = ConnectionStore(defaults: defaults())
        store.save(deepSeek(models: ["deepseek-pro", "deepseek-flash"]))
        #expect(store.defaultModel?.modelID == "deepseek-flash")
    }

    @Test func deepSeekWithoutFlashTakesTheFirstVisibleModel() {
        let store = ConnectionStore(defaults: defaults())
        store.save(deepSeek(models: ["deepseek-pro", "deepseek-lite"]))
        #expect(store.defaultModel?.modelID == "deepseek-pro")
    }

    @Test func hiddenFlashIsNotChosenAsDefault() {
        let store = ConnectionStore(defaults: defaults())
        var connection = deepSeek(models: ["deepseek-pro", "deepseek-flash"])
        connection.hiddenModelIDs = ["deepseek-flash"]
        store.save(connection)
        #expect(store.defaultModel?.modelID == "deepseek-pro")
    }

    @Test func otherPlatformsTakeTheFirstModel() {
        let store = ConnectionStore(defaults: defaults())
        var connection = Connection.openRouter()
        connection.models = [ModelInfo(id: "z/model"), ModelInfo(id: "deepseek-flash")]
        store.save(connection)
        #expect(store.defaultModel?.modelID == "z/model")
    }

    @Test func hiddenModelIsNotChosenAsDefault() {
        let store = ConnectionStore(defaults: defaults())
        var connection = deepSeek()
        connection.hiddenModelIDs = ["deepseek-flash"]
        store.save(connection)
        #expect(store.defaultModel?.modelID == "deepseek-pro")
    }

    @Test func persistsAcrossInstances() {
        let defaults = defaults()
        let connection = deepSeek()
        let first = ConnectionStore(defaults: defaults)
        first.save(connection)
        first.setManualModelIDs(["custom-1"], of: connection.id)

        let second = ConnectionStore(defaults: defaults)
        #expect(second.connections == [connection])
        #expect(second.defaultModel == first.defaultModel)
        #expect(second.manualModelIDs(of: connection.id) == ["custom-1"])
    }

    @Test func savingExistingConnectionReplacesIt() {
        let store = ConnectionStore(defaults: defaults())
        var connection = deepSeek()
        store.save(connection)
        connection.name = "Renamed"
        store.save(connection)
        #expect(store.connections.map(\.name) == ["Renamed"])
    }

    @Test func deletingConnectionClearsItsDefaultModelAndManualIDs() {
        let store = ConnectionStore(defaults: defaults())
        let connection = deepSeek()
        store.save(connection)
        store.setManualModelIDs(["x"], of: connection.id)
        store.delete(connection.id)
        #expect(store.connections.isEmpty)
        #expect(store.defaultModel == nil)
        #expect(store.manualModelIDs(of: connection.id).isEmpty)
        #expect(store.resolvedDefaultModel() == nil)
    }

    @Test func deletingAnotherConnectionKeepsDefaultModel() {
        let store = ConnectionStore(defaults: defaults())
        let first = deepSeek()
        let second = Connection.openRouter()
        store.save(first)
        store.save(second)
        store.delete(second.id)
        #expect(store.defaultModel?.connectionID == first.id)
        #expect(store.resolvedDefaultModel()?.modelID == "deepseek-flash")
    }

    @Test func visibleModelsDropHiddenOnes() {
        let store = ConnectionStore(defaults: defaults())
        var connection = deepSeek()
        connection.hiddenModelIDs = ["deepseek-pro"]
        #expect(store.visibleModels(of: connection).map(\.id) == ["deepseek-flash"])
    }
}
