import Foundation
import Testing

@testable import NotesCore

struct BoardStateTests {
    private let a = UUID()
    private let b = UUID()
    private let c = UUID()

    @Test func onlyOneRowExpandedAtATime() {
        var state = BoardState()
        let r1 = state.toggleExpanded(a)
        #expect(r1)
        #expect(state.expandedID == a)
        let r2 = state.toggleExpanded(b)
        #expect(r2)
        #expect(state.expandedID == b)
        #expect(state.selectedID == b)
        let r3 = state.toggleExpanded(b)
        #expect(r3)
        #expect(state.expandedID == nil)
        #expect(state.selectedID == b)  // 收起后仍选中，⌫ 可用
    }

    @Test func editingBlocksSwitchingAndCollapsing() {
        var state = BoardState()
        state.toggleExpanded(a)
        let r4 = state.beginEditing(a)
        #expect(r4)
        let r5 = state.toggleExpanded(b)
        #expect(!r5)
        let r6 = state.toggleExpanded(a)
        #expect(!r6)
        #expect(state.expandedID == a)
        #expect(state.deletableID == nil)
        state.endEditing()
        let r7 = state.toggleExpanded(b)
        #expect(r7)
        #expect(state.deletableID == b)
    }

    @Test func onlyExpandedRowCanBeEdited() {
        var state = BoardState()
        let r8 = state.beginEditing(a)
        #expect(!r8)
        state.toggleExpanded(a)
        let r9 = state.beginEditing(b)
        #expect(!r9)
        let r10 = state.beginEditing(a)
        #expect(r10)
        let r11 = state.beginEditing(a)
        #expect(!r11)
    }

    @Test func removedRowsLoseTheirState() {
        var state = BoardState()
        state.toggleExpanded(a)
        state.beginEditing(a)
        state.reconcile(existing: [b, c])
        #expect(state.expandedID == nil)
        #expect(state.editingID == nil)
        #expect(state.selectedID == nil)
        #expect(state.deletableID == nil)
    }

    @Test func highlightWaitsForRowToAppear() {
        var state = BoardState()
        state.requestHighlight([a, b])
        // observe 先只发来 a
        let r12 = state.reconcile(existing: [a, c])
        #expect(r12 == [a])
        #expect(state.highlightedIDs == [a])
        // 之后 b 也到了
        let r13 = state.reconcile(existing: [a, b, c])
        #expect(r13 == [b])
        #expect(state.highlightedIDs == [a, b])
        // 再刷新不重复开始
        let r14 = state.reconcile(existing: [a, b, c])
        #expect(r14.isEmpty)
    }

    @Test func highlightExpires() {
        var state = BoardState()
        state.requestHighlight([a])
        let started = state.reconcile(existing: [a])
        state.expireHighlight(started)
        #expect(state.highlightedIDs.isEmpty)
        // 过期后刷新不会再次高亮
        let r15 = state.reconcile(existing: [a])
        #expect(r15.isEmpty)
    }

    @Test func newRequestReplacesOldOne() {
        var state = BoardState()
        state.requestHighlight([a])
        state.reconcile(existing: [a, b])
        state.requestHighlight([b])
        #expect(state.highlightedIDs.isEmpty)
        let r16 = state.reconcile(existing: [a, b])
        #expect(r16 == [b])
        #expect(state.highlightedIDs == [b])
    }

    @Test func deletedRowStopsBeingHighlighted() {
        var state = BoardState()
        state.requestHighlight([a])
        state.reconcile(existing: [a])
        state.reconcile(existing: [])
        #expect(state.highlightedIDs.isEmpty)
    }

    // MARK: 编辑中的各种退出路径（不能卡死）

    private func editing(_ id: UUID) -> BoardState {
        var state = BoardState()
        state.toggleExpanded(id)
        state.beginEditing(id)
        return state
    }

    @Test func clickingAnotherRowWaitsForSaveThenExpandsIt() {
        var state = editing(a)
        state.setEditorAvailable(true)
        let handled = state.requestToggle(b)
        #expect(!handled)  // 要先让编辑器提交
        #expect(state.editingID == a)
        state.saveFinished(id: a, succeeded: true)
        #expect(state.editingID == nil)
        #expect(state.expandedID == b)
    }

    @Test func failedSaveKeepsEditingAndEscStillExits() {
        var state = editing(a)
        state.setEditorAvailable(true)
        _ = state.requestToggle(b)
        state.saveFinished(id: a, succeeded: false)
        #expect(state.editingID == a)  // 用户输入还在
        #expect(state.expandedID == a)  // 没有去展开 b
        // 再点一次会重试
        #expect(!state.requestToggle(b))
        state.saveFinished(id: a, succeeded: false)
        #expect(state.editingID == a)
        // Esc 永远能退出，之后可以正常展开别的行
        state.cancelEditing()
        #expect(state.editingID == nil)
        #expect(state.requestToggle(c))
        #expect(state.expandedID == c)
    }

    @Test func escDropsThePendingExpand() {
        var state = editing(a)
        state.setEditorAvailable(true)
        _ = state.requestToggle(b)
        state.cancelEditing()
        state.saveFinished(id: a, succeeded: true)  // 迟到的保存结果
        #expect(state.expandedID == a)
        #expect(state.editingID == nil)
    }

    @Test func unchangedEditFinishesAndExpandsTheClickedRow() {
        var state = editing(a)
        state.setEditorAvailable(true)
        _ = state.requestToggle(b)
        state.finishEditingWithoutChanges()
        #expect(state.editingID == nil)
        #expect(state.expandedID == b)
    }

    @Test func lateSaveResultForAnotherRowIsIgnored() {
        var state = editing(a)
        state.setEditorAvailable(true)
        state.saveFinished(id: b, succeeded: true)
        #expect(state.editingID == a)
    }

    /// 编辑中勾选这条 Note 本身：它移进折叠着的 Done，编辑器随之消失。之后不能卡死。
    @Test func tickingTheNoteBeingEditedDoesNotWedgeTheBoard() {
        var state = editing(a)
        state.setEditorAvailable(true)
        // 列表刷新：a 已完成，Done 区折叠，所以不可见
        state.reconcile(existing: [a, b, c], visible: [b, c])
        #expect(state.editingID == nil)
        #expect(state.expandedID == nil)
        #expect(state.selectedID == nil)
        #expect(state.deletableID == nil)  // ⌫ 不会删到看不见的 Note
        state.setEditorAvailable(false)  // 编辑器消失
        #expect(state.requestToggle(b))
        #expect(state.expandedID == b)
    }

    /// 同上，但保存（update）失败：编辑器已经随这一行消失，状态仍然要恢复。
    @Test func tickingTheNoteBeingEditedWithFailedSaveDoesNotWedgeTheBoard() {
        var state = editing(a)
        state.setEditorAvailable(true)
        _ = state.requestToggle(b)
        state.reconcile(existing: [a, b, c], visible: [b, c])
        state.setEditorAvailable(false)
        state.saveFinished(id: a, succeeded: false)  // 失败的结果晚到
        #expect(state.editingID == nil)
        #expect(state.requestToggle(c))
        #expect(state.expandedID == c)
    }

    @Test func editorDisappearingEndsEditing() {
        var state = editing(a)
        state.setEditorAvailable(true)
        state.setEditorAvailable(false)
        #expect(state.editingID == nil)
        #expect(state.requestToggle(b))
    }

    @Test func requestToggleRecoversWhenEditorNeverAppeared() {
        var state = editing(a)  // beginEditing 之后编辑器还没出现
        #expect(state.requestToggle(b))
        #expect(state.editingID == nil)
        #expect(state.expandedID == b)
    }

    @Test func collapsedDoneHidesItsRows() {
        var state = BoardState()
        state.toggleExpanded(a)
        state.reconcile(existing: [a, b], visible: [b])
        #expect(state.expandedID == nil)
        #expect(state.selectedID == nil)
    }
}
