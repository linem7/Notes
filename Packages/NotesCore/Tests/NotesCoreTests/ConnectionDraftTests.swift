import Foundation
import Testing
@testable import NotesCore

struct ConnectionDraftTests {
    @Test func templatesFillBaseURL() {
        #expect(ConnectionDraft(template: .deepSeek).baseURL == "https://api.deepseek.com")
        #expect(ConnectionDraft(template: .openRouter).baseURL == "https://openrouter.ai/api/v1")
        #expect(ConnectionDraft(template: .bailian).baseURL == "https://dashscope.aliyuncs.com/compatible-mode/v1")
        #expect(ConnectionDraft(template: .custom).baseURL.isEmpty)
        #expect(ConnectionTemplate.allCases.count == 4)
    }

    @Test func templatesAreRecognisedAsTheirPlatform() {
        #expect(ConnectionTemplate.deepSeek.makeConnection().platform == .deepSeek)
        #expect(ConnectionTemplate.openRouter.makeConnection().platform == .openRouter)
        #expect(ConnectionTemplate.bailian.makeConnection().platform == .bailian)
        #expect(ConnectionTemplate.custom.makeConnection().platform == nil)
    }

    @Test func invalidBaseURLsAreRejected() {
        var draft = ConnectionDraft(template: .custom)
        for bad in ["", "https://", "ftp://example.com", "example.com", "not a url"] {
            draft.baseURL = bad
            #expect(draft.makeConnection() == nil, "\(bad)")
        }
        draft.baseURL = "  https://llm.example.com/v1  "
        #expect(draft.makeConnection()?.baseURL.absoluteString == "https://llm.example.com/v1")
    }

    @Test func emptyNameFallsBackToHost() {
        var draft = ConnectionDraft(template: .custom)
        draft.baseURL = "https://llm.example.com/v1"
        draft.name = "  "
        #expect(draft.makeConnection()?.name == "llm.example.com")
    }

    @Test func mergingKeepsManualIDsMissingFromFetchedList() {
        var draft = ConnectionDraft(template: .deepSeek)
        draft.models = [ModelInfo(id: "a"), ModelInfo(id: "mine"), ModelInfo(id: "found")]
        draft.manualModelIDs = ["mine", "found"]
        let merged = draft.merging(fetched: [ModelInfo(id: "a"), ModelInfo(id: "found")])
        #expect(merged.models.map(\.id) == ["a", "found", "mine"])
        // 手填的 "found" 这次拉到了，不再算手动的
        #expect(merged.manualModelIDs == ["mine"])
    }

    @Test func savedKeyIsReusedWhileTheOriginStaysTheSame() {
        var draft = ConnectionDraft(connection: .deepSeek(), manualModelIDs: [])
        #expect(!draft.requiresNewKey)
        #expect(draft.effectiveKey(pasted: "", saved: "sk-old") == "sk-old")
        // 只改路径或大小写，来源没变
        draft.baseURL = "https://API.deepseek.com/v1"
        #expect(!draft.requiresNewKey)
        #expect(draft.effectiveKey(pasted: "  ", saved: "sk-old") == "sk-old")
    }

    @Test func savedKeyIsNeverSentToAnotherHost() {
        var draft = ConnectionDraft(connection: .deepSeek(), manualModelIDs: [])
        draft.baseURL = "https://evil.example.com"
        #expect(draft.requiresNewKey)
        #expect(draft.effectiveKey(pasted: "", saved: "sk-old") == nil)
        // 重新粘贴了 key 就可以
        #expect(draft.effectiveKey(pasted: " sk-new \n", saved: "sk-old") == "sk-new")
    }

    @Test func changingSchemeOrPortAlsoRequiresANewKey() {
        var draft = ConnectionDraft(connection: .deepSeek(), manualModelIDs: [])
        draft.baseURL = "http://api.deepseek.com"
        #expect(draft.requiresNewKey)
        draft.baseURL = "https://api.deepseek.com:8443"
        #expect(draft.requiresNewKey)
        draft.baseURL = "not a url"
        #expect(draft.requiresNewKey)
    }

    @Test func newDraftNeverReusesAKey() {
        let draft = ConnectionDraft(template: .deepSeek)
        #expect(!draft.requiresNewKey)
        #expect(draft.effectiveKey(pasted: "", saved: nil) == nil)
    }

    @Test func editingExistingConnectionIsNotNew() {
        let connection = Connection.deepSeek()
        let draft = ConnectionDraft(connection: connection, manualModelIDs: ["x"])
        #expect(!draft.isNew)
        #expect(draft.makeConnection() == connection)
    }
}
