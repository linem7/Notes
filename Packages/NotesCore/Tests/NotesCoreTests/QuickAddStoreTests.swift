import Foundation
import Testing
@testable import NotesCore

@MainActor
struct QuickAddStoreTests {
    @MainActor
    final class Env {
        let intake: FakeIntake
        let organizer = FakeOrganizer()
        let saver = FakeSaver()
        let highlighter = FakeHighlighter()
        let store: QuickAddStore

        init(pendingTimeout: Duration = .seconds(5)) {
            let intake = FakeIntake()
            self.intake = intake
            store = QuickAddStore(
                organizer: organizer, saver: saver, makeIntake: { intake },
                pendingTimeout: pendingTimeout, linkDetectionDelay: .milliseconds(1),
                now: { Date(timeIntervalSince1970: 1_000) }
            )
            store.setHighlighter(highlighter)
        }
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<400 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private func url(_ name: String) -> URL { URL(fileURLWithPath: "/tmp/\(name)") }

    // MARK: Organize

    @Test func organizeProducesDrafts() async {
        let env = Env()
        env.store.inputText = "call Alex tomorrow"
        env.store.organize()
        #expect(env.store.phase == .organizing(received: 0))
        await waitUntil { env.store.phase == .drafts }
        #expect(env.store.phase == .drafts)
        #expect(env.store.drafts.count == 1)
        #expect(env.organizer.calls.first?.input == "call Alex tomorrow")
    }

    @Test func organizeNeedsInput() {
        let env = Env()
        env.store.inputText = "  \n"
        env.store.organize()
        #expect(env.store.phase == .idle)
        #expect(env.organizer.calls.isEmpty)
    }

    @Test func organizeWithOnlyMaterialIsAllowed() async {
        let env = Env()
        env.store.addFiles([url("a.pdf")])
        env.store.organize()
        await waitUntil { env.store.phase == .drafts }
        #expect(env.organizer.calls.first?.materials.count == 1)
    }

    @Test func organizeWaitsForPendingReadableText() async {
        let env = Env()
        env.store.addFiles([url("a.pdf")])
        env.store.organize()
        await waitUntil { env.store.phase == .drafts }
        guard case .ready = env.organizer.calls.first?.materials.first?.prepared.state else {
            Issue.record("Organize should have received the ready Readable Text")
            return
        }
    }

    @Test func pendingTimeoutTreatsMaterialAsUnavailable() async {
        let env = Env(pendingTimeout: .milliseconds(30))
        env.intake.hanging = ["slow.pdf"]
        env.store.addFiles([url("slow.pdf"), url("fast.pdf")])
        env.store.organize()
        await waitUntil { env.store.phase == .drafts }
        let materials = env.organizer.calls.first?.materials ?? []
        #expect(materials.count == 2)
        #expect(materials[0].prepared.state == .unavailable(.cancelled))
        // 到点真的取消了还在跑的 prepare，Material 条上也标为 unavailable
        await waitUntil { env.intake.cancelledNames.contains("slow.pdf") }
        #expect(env.intake.cancelledNames == ["slow.pdf"])
        #expect(env.store.items[0].state == .unavailable(.cancelled))
        guard case .ready = materials[1].prepared.state else {
            Issue.record("fast.pdf should be ready")
            return
        }
    }

    @Test func removingMaterialCancelsItsPrepare() async {
        let env = Env()
        env.intake.hanging = ["slow.pdf"]
        env.store.addFiles([url("slow.pdf")])
        env.store.removeItem(id: env.store.items[0].id)
        await waitUntil { env.intake.cancelledNames.contains("slow.pdf") }
        #expect(env.intake.cancelledNames == ["slow.pdf"])
    }

    @Test func clearCancelsPendingPrepare() async {
        let env = Env()
        env.intake.hanging = ["slow.pdf"]
        env.store.addFiles([url("slow.pdf")])
        env.store.clear()
        await waitUntil { env.intake.cancelledNames.contains("slow.pdf") }
        #expect(env.intake.cancelledNames == ["slow.pdf"])
    }

    @Test func reorganizeReplacesDrafts() async {
        let env = Env()
        env.store.inputText = "one"
        env.store.organize()
        await waitUntil { env.store.phase == .drafts }
        env.organizer.behavior = { _ in [Draft(title: "New", materialIndices: [])] }
        env.store.organize()
        #expect(env.store.drafts.isEmpty)
        await waitUntil { env.store.phase == .drafts }
        #expect(env.store.drafts.map(\.title) == ["New"])
    }

    @Test func cancelDuringOrganizeReturnsToIdleAndIgnoresLateResult() async {
        let env = Env()
        env.organizer.behavior = { _ in
            try await Task.sleep(for: .milliseconds(100))
            return [Draft(title: "Late", materialIndices: [])]
        }
        env.store.inputText = "x"
        env.store.organize()
        #expect(env.store.isOrganizing)
        env.store.cancelOrganize()
        #expect(env.store.phase == .idle)
        try? await Task.sleep(for: .milliseconds(200))
        #expect(env.store.phase == .idle)
        #expect(env.store.drafts.isEmpty)
        #expect(env.store.inputText == "x")
    }

    @Test func escapeCancelsOrganizeAndKeepsPanelOpen() async {
        let env = Env()
        env.organizer.behavior = { _ in
            try await Task.sleep(for: .seconds(5))
            return []
        }
        env.store.inputText = "x"
        env.store.organize()
        #expect(env.store.handleEscape() == true)
        #expect(env.store.phase == .idle)
        // 空闲时 Esc 不处理，由面板隐藏
        #expect(env.store.handleEscape() == false)
    }

    @Test func errorsMapToFailures() async {
        let env = Env()
        env.store.inputText = "x"
        env.organizer.behavior = { _ in throw ChatError.authentication }
        env.store.organize()
        await waitUntil { env.store.phase != .organizing(received: 0) && env.store.phase != .organizing(received: 12) }
        #expect(env.store.phase == .failed(.chat(.authentication)))

        env.organizer.behavior = { _ in throw OrganizeSetupError.noConnection }
        env.store.organize()
        await waitUntil { env.store.phase == .failed(.noConnection) }
        #expect(env.store.phase == .failed(.noConnection))
    }

    @Test func retryAfterFailureWorks() async {
        let env = Env()
        env.store.inputText = "x"
        env.organizer.behavior = { _ in throw ChatError.network }
        env.store.organize()
        await waitUntil { env.store.phase == .failed(.chat(.network)) }
        env.organizer.behavior = { _ in [Draft(title: "ok", materialIndices: [])] }
        env.store.organize()
        await waitUntil { env.store.phase == .drafts }
        #expect(env.store.drafts.count == 1)
    }

    @Test func noConnectionStillAllowsSaveAsIs() async {
        let env = Env()
        env.store.inputText = "Buy milk"
        env.organizer.behavior = { _ in throw OrganizeSetupError.noConnection }
        env.store.organize()
        await waitUntil { env.store.phase == .failed(.noConnection) }
        #expect(env.store.canSave)
        await env.store.save()
        #expect(env.saver.requests.count == 1)
    }

    // MARK: 保存

    @Test func saveDraftsSavesOnlySelectedWithSource() async {
        let env = Env()
        env.organizer.behavior = { _ in
            [Draft(title: "A", materialIndices: [0]), Draft(title: "B", materialIndices: [], isSelected: false)]
        }
        env.store.inputText = "chat text"
        env.store.addFiles([url("a.pdf")])
        env.store.organize()
        await waitUntil { env.store.phase == .drafts }
        var didSave = false
        env.store.onDidSave = { didSave = true }
        await env.store.save()

        let request = env.saver.requests.first
        #expect(request?.entries.map(\.title) == ["A"])
        #expect(request?.entries.first?.includesSource == true)
        #expect(request?.entries.first?.materialIndices == [0])
        #expect(request?.sourceText == "chat text")
        #expect(didSave)
        #expect(env.highlighter.highlighted.count == 1)
        // 保存后回到空白
        #expect(env.store.hasContent == false)
        #expect(env.store.phase == .idle)
        #expect(env.intake.discarded)
        #expect(env.store.currentStagingSessionID == nil)
    }

    @Test func saveAsIsHasNoSourceAndAttachesEverything() async {
        let env = Env()
        env.store.inputText = "Title line\nrest"
        env.store.addFiles([url("a.pdf"), url("b.txt")])
        await env.store.save()
        let entry = env.saver.requests.first?.entries.first
        #expect(entry?.title == "Title line")
        #expect(entry?.detail == "rest")
        #expect(entry?.includesSource == false)
        #expect(entry?.materialIndices == [0, 1])
    }

    @Test func saveDisabledWhenNothingSelectedOrEmpty() async {
        let env = Env()
        #expect(env.store.canSave == false)
        env.store.inputText = "x"
        env.store.organize()
        await waitUntil { env.store.phase == .drafts }
        env.store.drafts[0].isSelected = false
        #expect(env.store.canSave == false)
        await env.store.save()
        #expect(env.saver.requests.isEmpty)
    }

    @Test func saveFailureKeepsEverything() async {
        let env = Env()
        env.saver.error = NoteStoreError.duplicateID(UUID())
        env.store.inputText = "x"
        env.store.organize()
        await waitUntil { env.store.phase == .drafts }
        await env.store.save()
        #expect(env.store.saveFailed)
        #expect(env.store.phase == .drafts)
        #expect(env.store.drafts.count == 1)
        #expect(env.store.inputText == "x")
        #expect(env.highlighter.highlighted.isEmpty)
    }

    @Test func removedMaterialIsNotAttachedAndDetachWorks() async {
        let env = Env()
        env.organizer.behavior = { _ in [Draft(title: "A", materialIndices: [0, 1, 2])] }
        env.store.inputText = "x"
        env.store.addFiles([url("a.pdf"), url("b.pdf"), url("c.pdf")])
        env.store.organize()
        await waitUntil { env.store.phase == .drafts }
        let ids = env.store.items.map(\.id)
        env.store.removeItem(id: ids[0])
        env.store.detach(materialID: ids[1], from: env.store.drafts[0].id)
        #expect(env.store.materials(of: env.store.drafts[0]).map(\.displayName) == ["c.pdf"])
        await env.store.save()
        let request = env.saver.requests.first
        #expect(request?.materials.map(\.staged.displayName) == ["b.pdf", "c.pdf"])
        #expect(request?.entries.first?.materialIndices == [1])
    }

    // MARK: 隐藏 / 清空

    @Test func hasUnsavedWorkTracksInputDraftsAndOrganize() async {
        let env = Env()
        #expect(env.store.hasUnsavedWork == false)
        env.store.inputText = "x"
        #expect(env.store.hasUnsavedWork)
        env.store.clear()
        #expect(env.store.hasUnsavedWork == false)
        #expect(env.store.inputText.isEmpty)
        #expect(env.store.currentStagingSessionID == nil)
    }

    @Test func clearCancelsOrganizeAndDiscardsStaging() async {
        let env = Env()
        env.organizer.behavior = { _ in
            try await Task.sleep(for: .seconds(5))
            return []
        }
        env.store.inputText = "x"
        env.store.addFiles([url("a.pdf")])
        #expect(env.store.currentStagingSessionID == env.intake.sessionID)
        env.store.organize()
        env.store.clear()
        #expect(env.store.phase == .idle)
        #expect(env.store.items.isEmpty)
        #expect(env.intake.discarded)
    }

    // MARK: Material

    @Test func stageFailureShowsWarningChip() {
        let env = Env()
        env.intake.failingNames = ["bad.pdf"]
        env.store.addFiles([url("bad.pdf"), url("ok.pdf")])
        #expect(env.store.items.map(\.staged.displayName) == ["ok.pdf"])
        #expect(env.store.stageFailures.map(\.name) == ["bad.pdf"])
        env.store.removeStageFailure(id: env.store.stageFailures[0].id)
        #expect(env.store.stageFailures.isEmpty)
    }

    @Test func pastedImageIsAdded() {
        let env = Env()
        env.store.addImageData(Data([1, 2, 3]))
        #expect(env.store.items.count == 1)
    }

    @Test func prepareResultUpdatesItem() async {
        let env = Env()
        env.intake.results["a.pdf"] = PreparedText(state: .unavailable(.noTextRecognized))
        env.store.addFiles([url("a.pdf")])
        #expect(env.store.items[0].state == .pending)
        await waitUntil { env.store.items.first?.state != .pending }
        #expect(env.store.items[0].state == .unavailable(.noTextRecognized))
    }

    // MARK: 链接

    @Test func linksInTextBecomeWebPageItemsAndAreRemovedWithTheText() async {
        let env = Env()
        env.store.inputText = "see https://example.com/a and https://example.com/b"
        await waitUntil { env.store.items.count == 2 }
        #expect(env.store.items.map(\.staged.kind) == [.webPage, .webPage])

        env.store.inputText = "see https://example.com/a"
        await waitUntil { env.store.items.count == 1 }
        #expect(env.store.items.first?.staged.url?.absoluteString == "https://example.com/a")
    }

    @Test func dismissedLinkIsNotAddedAgainButTextStays() async {
        let env = Env()
        env.store.inputText = "https://example.com/a"
        await waitUntil { env.store.items.count == 1 }
        env.store.removeItem(id: env.store.items[0].id)
        env.store.detectLinks()
        #expect(env.store.items.isEmpty)
        env.store.inputText += " more"
        env.store.detectLinks()
        #expect(env.store.items.isEmpty)
        #expect(env.store.inputText.contains("https://example.com/a"))
    }

    @Test func manuallyAddedFileIsNotDroppedByLinkDetection() async {
        let env = Env()
        env.store.addFiles([url("a.pdf")])
        env.store.inputText = "no links"
        env.store.detectLinks()
        #expect(env.store.items.count == 1)
    }

    @Test func organizeDetectsPendingLinksImmediately() async {
        let env = Env()
        env.store.inputText = "https://example.com/a"
        env.store.organize()
        await waitUntil { env.store.phase == .drafts }
        #expect(env.organizer.calls.first?.materials.count == 1)
    }
}
