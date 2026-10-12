import Foundation
import Synchronization
import Testing
@testable import NotesCore

/// 假的模型：记下收到的参数，按剧本吐出片段或错误。
private final class StubModel: OrganizeModelClient {
    struct Call: Sendable {
        var system: String
        var user: String
        var modelID: String
        var apiKey: String
        var jsonMode: Bool
    }

    enum Script: Sendable {
        case fragments([String])
        case fail([String], ChatError)
        /// 一直等到被取消
        case hang
    }

    private let script: Script
    private let recorded = Mutex<[Call]>([])
    private let cancelled = Mutex(false)

    init(_ script: Script) { self.script = script }

    var calls: [Call] { recorded.withLock { $0 } }
    var wasCancelled: Bool { cancelled.withLock { $0 } }

    func complete(
        system: String, user: String, modelID: String, connection: Connection, apiKey: String, jsonMode: Bool
    ) -> AsyncThrowingStream<String, any Error> {
        recorded.withLock { $0.append(Call(system: system, user: user, modelID: modelID, apiKey: apiKey, jsonMode: jsonMode)) }
        return AsyncThrowingStream { continuation in
            let task = Task {
                switch script {
                case .fragments(let fragments):
                    for fragment in fragments { continuation.yield(fragment) }
                    continuation.finish()
                case .fail(let fragments, let error):
                    for fragment in fragments { continuation.yield(fragment) }
                    continuation.finish(throwing: error)
                case .hang:
                    while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
                    continuation.finish(throwing: CancellationError())
                }
            }
            continuation.onTermination = { [self] _ in
                cancelled.withLock { $0 = true }
                task.cancel()
            }
        }
    }
}

struct OrganizerTests {
    private let now = Date(timeIntervalSince1970: 1_791_806_400)
    private let utc = TimeZone(identifier: "UTC")!

    private func organize(
        _ model: StubModel,
        input: String = "Send the contract to Alex by Thursday",
        materials: [PromptMaterial] = [],
        userPrompt: String = OrganizePrompt.default,
        onProgress: (@Sendable (Int) -> Void)? = nil
    ) async throws -> [Draft] {
        try await Organizer(client: model).organize(
            input: input, promptMaterials: materials, connection: .deepSeek(), modelID: "deepseek-flash", apiKey: "sk-test",
            userPrompt: userPrompt, now: now, timeZone: utc, onProgress: onProgress
        )
    }

    @Test func sendsTheAssembledPromptsInJSONMode() async throws {
        let model = StubModel(.fragments(["{\"notes\": []}"]))
        let material = PromptMaterial(kind: .file, name: "a.txt", text: "hi")
        _ = try await organize(model, materials: [material], userPrompt: "CUSTOM")

        let call = try #require(model.calls.first)
        #expect(call.system == OrganizePrompt.system(now: now, timeZone: utc, prompt: "CUSTOM"))
        #expect(call.user == OrganizePrompt.userMessage(input: "Send the contract to Alex by Thursday", materials: [material]))
        #expect(call.modelID == "deepseek-flash")
        #expect(call.apiKey == "sk-test")
        #expect(call.jsonMode)
    }

    @Test func joinsFragmentsAndParsesTheDrafts() async throws {
        let model = StubModel(.fragments([
            "```json\n{\"notes\": [{\"title\": \"Send the contract to Alex\", ",
            "\"due\": \"2026-10-15\", \"time\": null, \"detail\": \"- email\", \"materials\": [1]}]}\n```",
        ]))
        let drafts = try await organize(model, materials: [PromptMaterial(kind: .file, name: "a.txt", text: "hi")])
        #expect(drafts.count == 1)
        #expect(drafts[0].title == "Send the contract to Alex")
        #expect(drafts[0].due == DueDate(day: "2026-10-15", time: nil))
        #expect(drafts[0].materialIndices == [0])
    }

    @Test func unparsableOutputGivesAFallbackDraftInsteadOfAnError() async throws {
        let model = StubModel(.fragments(["not json at all"]))
        let drafts = try await organize(model, input: "Call the dentist\nTomorrow")
        #expect(drafts.count == 1)
        #expect(drafts[0].title == "Call the dentist")
        #expect(drafts[0].detail == "not json at all")
    }

    @Test func reportsProgressAsTheTextArrives() async throws {
        let model = StubModel(.fragments(["{\"notes\"", ": []}"]))
        let seen = Mutex<[Int]>([])
        _ = try await organize(model) { count in seen.withLock { $0.append(count) } }
        #expect(seen.withLock { $0 } == [8, 13])
    }

    @Test func modelErrorsArePassedThrough() async throws {
        await #expect(throws: ChatError.authentication) {
            try await organize(StubModel(.fail([], .authentication)))
        }
        await #expect(throws: ChatError.network) {
            try await organize(StubModel(.fail(["{\"notes\""], .network)))
        }
    }

    @Test func cancellingStopsTheModelCallAndThrowsCancellationError() async throws {
        let model = StubModel(.hang)
        let task = Task { try await organize(model) }
        for _ in 0..<500 where model.calls.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        task.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
        for _ in 0..<500 where !model.wasCancelled { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.wasCancelled)
    }
}
