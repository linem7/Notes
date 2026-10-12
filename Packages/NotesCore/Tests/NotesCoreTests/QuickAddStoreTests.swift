import Foundation
import Testing
@testable import NotesCore

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct QuickAddStoreTests {
    @MainActor
    final class Env {
        let intake: FakeIntake
        let organizer = FakeOrganizer()
        let saver = FakeSaver()
        let highlighter = FakeHighlighter()
        let store: QuickAddStore

        init(pendingTimeout: Duration = .seconds(5), saveTimeout: Duration = .seconds(5)) {
            let intake = FakeIntake()
            self.intake = intake
            store = QuickAddStore(
                organizer: organizer, saver: saver, makeIntake: { intake },
                pendingTimeout: pendingTimeout, saveTimeout: saveTimeout, linkDetectionDelay: .milliseconds(1),
                now: { Date(timeIntervalSince1970: 1_000) }
            )
            store.setHighlighter(highlighter)
        }
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<400 {
            if condition() { return }
            // 取消时直接退出：`try?` 吞掉取消会让循环失去挂起点
            do { try await Task.sleep(for: .milliseconds(5)) } catch { return }
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

    @Test func pendingTimeoutCancelsPrepareAndMarksUnavailable() async {
        let env = Env(pendingTimeout: .milliseconds(30))
        env.intake.hanging = ["slow.pdf", "https://slow.example.com/"]
        env.store.addFiles([url("slow.pdf"), url("fast.pdf")])
        env.store.inputText = "https://slow.example.com/"
        env.store.detectLinks()
        env.store.organize()
        await waitUntil { env.store.phase == .drafts }
        let materials = env.organizer.calls.first?.materials ?? []
        guard materials.count == 3 else {
            Issue.record("expected 3 materials, got \(materials.count)")
            return
        }
        // 文件 → notReadable，网页 → pageLoadFailed；.cancelled 只给用户自己的移除 / 清空
        #expect(materials[0].prepared.state == .unavailable(.notReadable))
        guard case .ready = materials[1].prepared.state else {
            Issue.record("fast.pdf should be ready")
            return
        }
        #expect(materials[2].prepared.state == .unavailable(.pageLoadFailed))
        // 到点真的取消了还在跑的 prepare
        await waitUntil { env.intake.cancelledNames.count == 2 }
        #expect(env.intake.cancelledNames == ["slow.pdf", "https://slow.example.com/"])
        #expect(env.store.items[0].state == .unavailable(.notReadable))
    }

    @Test func prepareThatIgnoresCancellationStillTimesOutOnTime() async {
        let env = Env(pendingTimeout: .milliseconds(30))
        env.intake.stubborn = ["stuck.pdf"]
        env.store.addFiles([url("stuck.pdf")])
        env.store.organize()
        await waitUntil { env.store.phase == .drafts }
        env.intake.release()
        #expect(env.store.phase == .drafts)
        #expect(env.organizer.calls.first?.materials.first?.prepared.state == .unavailable(.notReadable))
    }

    /// 取消之后的等待必须真的挂起。旧写法 `while !gate { try? await Task.sleep(5ms) }` 一旦被取消，
    /// `Task.sleep` 立刻抛、`try?` 吞掉，循环失去挂起点 → 紧忙等占死协作线程（CI 整轮测试被钉死就是这么来的）。
    @Test func cancelledStubbornPrepareStopsPollingTheGate() async {
        let env = Env(pendingTimeout: .milliseconds(30))
        env.intake.stubborn = ["stuck.pdf"]
        env.store.addFiles([url("stuck.pdf")])
        env.store.organize()
        // pending 超时 → prepare 被取消，此刻它应该挂在闸门上
        await waitUntil { env.store.phase == .drafts }
        let before = env.intake.releaseReads
        try? await Task.sleep(for: .milliseconds(200))
        let during = env.intake.releaseReads - before
        env.intake.release()
        // 200ms 内最多看一眼闸门；忙等的话这里是几万次
        #expect(during <= 1, "取消后 200ms 内重查闸门 \(during) 次（应为 ≤ 1；旧的忙等写法这里是 239806 次）")
    }

    /// 取消之后的等待不得阻止无关的 async 工作推进：起 K = 核数 + 4 个「被取消后仍在等」的桩，
    /// 再让一个无关的 detached 任务跑一小段 —— 它必须在 1 秒内跑完（旧写法会把协作线程占死）。
    ///
    /// 失败形态也要能收场：旧写法下这些等待会把协作池占死，测试体自己都可能一直醒不过来。
    /// 所以除了正常路径的 `release()`，还有一个挂在 **libdispatch 自己的线程上**（不是协作池）的
    /// 3 秒兜底开闸 —— 池子被占死时它照样准时开闸，让池子恢复、让断言和 `✘` 打得出来，
    /// 而不是把整轮测试钉死到 15 分钟超时。
    /// 兜底松闸只会让 `elapsed` 变**小**，不可能变大：观测到 `elapsed ≥ 1 秒`，
    /// 只能是「无关工作在 1 秒内确实没跑完」，松闸没帮忙圆谎。
    @Test func cancelledWaitsDoNotBlockUnrelatedWork() async {
        let box = FlagBox()
        let env = Env()
        let names = (0..<(ProcessInfo.processInfo.activeProcessorCount + 4)).map { "stuck\($0).pdf" }
        env.intake.stubborn = Set(names)
        env.store.addFiles(names.map { url($0) })
        // 取消全部 prepare：它们停在闸门前（旧写法在这里变成忙等）
        env.store.clear()

        // 兜底开闸：libdispatch 的线程不是协作池，池子被占死时它仍然准时。
        let intake = env.intake
        DispatchQueue.global().asyncAfter(deadline: .now() + 3.0) { intake.release() }

        let start = Date()
        Task.detached {
            var sum = 0
            for i in 0..<2_000_000 { sum &+= i }
            box.set(sum != 0)
        }
        await waitUntil { box.isSet }
        let elapsed = Date().timeIntervalSince(start)   // 先取快照
        intake.release()                                // 再正常开闸
        #expect(box.isSet)
        #expect(elapsed < 1.0, "无关任务跑了 \(elapsed) 秒 —— 取消后的等待占了协作线程（旧的忙等写法下这里是一整轮钉死）")
    }

    @Test func saveWaitsForPendingReadableText() async {
        let env = Env()
        env.intake.delays = ["a.pdf": .milliseconds(60)]
        env.intake.results = ["a.pdf": PreparedText(state: .ready("late text"))]
        env.store.addFiles([url("a.pdf")])
        env.store.inputText = "note"
        await env.store.save()
        guard let request = env.saver.requests.first else {
            Issue.record("expected a save request")
            return
        }
        #expect(request.materials.first?.prepared.state == .ready("late text"))
    }

    @Test func saveTimesOutOnStuckPrepareAndStillSaves() async {
        let env = Env(pendingTimeout: .milliseconds(30))
        env.intake.stubborn = ["stuck.pdf"]
        env.store.addFiles([url("stuck.pdf")])
        env.store.inputText = "note"
        await env.store.save()
        env.intake.release()
        #expect(env.saver.requests.count == 1)
    }

    @Test func cancelWorksEvenIfOrganizerIgnoresCancellation() async {
        let env = Env()
        let gate = Gate()
        env.organizer.behavior = { _ in
            // 完全不理会取消，直到测试放行（挂起等待，不轮询）
            await gate.wait()
            return [Draft(title: "Late", materialIndices: [])]
        }
        env.store.inputText = "x"
        env.store.organize()
        env.store.cancelOrganize()
        #expect(env.store.phase == .idle)
        gate.open()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(env.store.phase == .idle)
        #expect(env.store.drafts.isEmpty)
    }

    @Test func cancelKeepsOldDraftsAndEditsAndFailureToo() async {
        let env = Env()
        env.store.inputText = "x"
        env.store.organize()
        await waitUntil { env.store.phase == .drafts }
        env.store.drafts[0].title = "Edited"
        env.organizer.behavior = { _ in
            try await Task.sleep(for: .seconds(5))
            return []
        }
        env.store.organize()
        #expect(env.store.drafts.map(\.title) == ["Edited"])
        env.store.cancelOrganize()
        #expect(env.store.phase == .drafts)
        #expect(env.store.drafts.map(\.title) == ["Edited"])

        env.organizer.behavior = { _ in throw ChatError.network }
        env.store.organize()
        await waitUntil { env.store.phase == .failed(.chat(.network)) }
        #expect(env.store.drafts.map(\.title) == ["Edited"])
    }

    @Test func stagingSessionIDFollowsTheSession() async {
        let env = Env()
        #expect(env.store.currentStagingSessionID == nil)
        env.store.addFiles([url("a.pdf")])
        #expect(env.store.currentStagingSessionID == env.intake.sessionID)
        await env.store.save()
        #expect(env.store.currentStagingSessionID == nil)
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
        await waitUntil { env.store.drafts.map(\.title) == ["New"] }
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

    @Test func saveTimesOutWhenSaverNeverReturnsAndCanRetry() async {
        let env = Env(saveTimeout: .milliseconds(40))
        let gate = Gate()
        env.saver.hang = gate
        env.store.inputText = "x"
        await env.store.save()
        #expect(env.store.saveFailed)
        #expect(env.store.isSaving == false)
        #expect(env.store.inputText == "x")
        #expect(env.highlighter.highlighted.isEmpty)
        gate.open()
        env.saver.hang = nil
        await env.store.save()
        #expect(env.saver.requests.count == 2)
        #expect(env.store.hasContent == false)
    }

    @Test func clearIsIgnoredWhileSaving() async {
        let env = Env()
        env.intake.delays = ["a.pdf": .milliseconds(80)]
        env.store.addFiles([url("a.pdf")])
        env.store.inputText = "x"
        let saving = Task { await env.store.save() }
        await waitUntil { env.store.isSaving }
        env.store.clear()
        #expect(env.store.inputText == "x")
        #expect(env.intake.discarded == false)
        await saving.value
        #expect(env.saver.requests.count == 1)
    }

    @Test func draftWithBlankTitleCannotBeSaved() async {
        let env = Env()
        env.store.inputText = "x"
        env.store.organize()
        await waitUntil { env.store.phase == .drafts }
        #expect(env.store.canSave)
        env.store.drafts[0].title = "   "
        #expect(env.store.canSave == false)
        // 取消勾选后不再卡住保存
        env.store.drafts[0].isSelected = false
        env.store.drafts.append(Draft(title: "Ok", materialIndices: []))
        #expect(env.store.canSave)
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

    // MARK: 数据库打不开（SPEC §2.2）

    /// 现取不到 store 时保存失败，但输入一个字都不能丢。
    @Test func saveWithoutStoreFailsAndKeepsInput() async {
        let files = MaterialFiles(root: FileManager.default.temporaryDirectory.appendingPathComponent("QuickAddResolve-\(UUID().uuidString)"))
        let intake = FakeIntake()
        let store = QuickAddStore(
            organizer: FakeOrganizer(),
            saver: ResolvingQuickAddSaver(files: files, resolve: { nil }),
            makeIntake: { intake },
            saveTimeout: .seconds(5), linkDetectionDelay: .milliseconds(1)
        )

        store.inputText = "buy milk"
        #expect(store.canSave)

        await store.save()

        #expect(store.saveFailed)
        #expect(store.inputText == "buy milk")
        // 一个文件都没写，也就没有 Note 产生
        let written = (try? FileManager.default.contentsOfDirectory(atPath: files.filesDirectory.path)) ?? []
        #expect(written.isEmpty)
    }
}

/// 一个线程安全的布尔盒子（跨任务读结果用）。
final class FlagBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _isSet = false
    var isSet: Bool { lock.withLock { _isSet } }
    func set(_ value: Bool) { lock.withLock { _isSet = value } }
}

/// 手动开关：`wait()` 一直等到 `open()`，等待者真的挂起，不靠睡眠轮询。
/// 轮询在这里是有害的：等的一方被取消后 `try? await Task.sleep` 立刻抛、循环不再挂起，
/// 就变成占死协作线程的紧忙等（同 `WebFetchSupportTests` 里那个 `Gate`）。
final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var _open = false
    private var _reads = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// 测试用：闸门状态被查看过几次。取消之后这个数还在涨，就是退化成忙等了。
    var reads: Int { lock.withLock { _reads } }

    var isOpen: Bool {
        lock.withLock {
            _reads += 1
            return _open
        }
    }

    func open() {
        let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            _open = true
            defer { self.waiters = [] }
            return self.waiters
        }
        for waiter in waiters { waiter.resume() }
    }

    /// 挂起直到 `open()`。**不看取消**（这些桩要的就是「不理会取消」），但也绝不占线程。
    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let alreadyOpen = lock.withLock { () -> Bool in
                _reads += 1
                if _open { return true }
                waiters.append(continuation)
                return false
            }
            if alreadyOpen { continuation.resume() }
        }
    }
}
