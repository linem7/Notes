import Foundation
import Testing

@testable import NotesCore

struct BoardStateTests {
    private let a = UUID()
    private let b = UUID()
    private let c = UUID()

    @Test func onlyOneRowExpandedAtATime() {
        var state = BoardState()
        let result = state.toggleExpanded(a)
        #expect(r1)
        #expect(state.expandedID == a)
        let result = state.toggleExpanded(b)
        #expect(r2)
        #expect(state.expandedID == b)
        #expect(state.selectedID == b)
        let result = state.toggleExpanded(b)
        #expect(r3)
        #expect(state.expandedID == nil)
        #expect(state.selectedID == b)  // 收起后仍选中，⌫ 可用
    }

    @Test func editingBlocksSwitchingAndCollapsing() {
        var state = BoardState()
        state.toggleExpanded(a)
        let result = state.beginEditing(a)
        #expect(r4)
        let result = state.toggleExpanded(b)
        #expect(!r5)
        let result = state.toggleExpanded(a)
        #expect(!r6)
        #expect(state.expandedID == a)
        #expect(state.deletableID == nil)
        state.endEditing()
        let result = state.toggleExpanded(b)
        #expect(r7)
        #expect(state.deletableID == b)
    }

    @Test func onlyExpandedRowCanBeEdited() {
        var state = BoardState()
        let result = state.beginEditing(a)
        #expect(!r8)
        state.toggleExpanded(a)
        let result = state.beginEditing(b)
        #expect(!r9)
        let result = state.beginEditing(a)
        #expect(r10)
        let result = state.beginEditing(a)
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
        let result = state.reconcile(existing: [a, c])
        #expect(r12 == [a])
        #expect(state.highlightedIDs == [a])
        // 之后 b 也到了
        let result = state.reconcile(existing: [a, b, c])
        #expect(r13 == [b])
        #expect(state.highlightedIDs == [a, b])
        // 再刷新不重复开始
        let result = state.reconcile(existing: [a, b, c])
        #expect(r14.isEmpty)
    }

    @Test func highlightExpires() {
        var state = BoardState()
        state.requestHighlight([a])
        let started = state.reconcile(existing: [a])
        state.expireHighlight(started)
        #expect(state.highlightedIDs.isEmpty)
        // 过期后刷新不会再次高亮
        let result = state.reconcile(existing: [a])
        #expect(r15.isEmpty)
    }

    @Test func newRequestReplacesOldOne() {
        var state = BoardState()
        state.requestHighlight([a])
        state.reconcile(existing: [a, b])
        state.requestHighlight([b])
        #expect(state.highlightedIDs.isEmpty)
        let result = state.reconcile(existing: [a, b])
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
}
