import Foundation
import Testing

@testable import NotesCore

struct BoardStateTests {
    private let a = UUID()
    private let b = UUID()
    private let c = UUID()

    @Test func onlyOneRowExpandedAtATime() {
        var state = BoardState()
        #expect(state.toggleExpanded(a))
        #expect(state.expandedID == a)
        #expect(state.toggleExpanded(b))
        #expect(state.expandedID == b)
        #expect(state.selectedID == b)
        #expect(state.toggleExpanded(b))
        #expect(state.expandedID == nil)
        #expect(state.selectedID == b)  // 收起后仍选中，⌫ 可用
    }

    @Test func editingBlocksSwitchingAndCollapsing() {
        var state = BoardState()
        state.toggleExpanded(a)
        #expect(state.beginEditing(a))
        #expect(!state.toggleExpanded(b))
        #expect(!state.toggleExpanded(a))
        #expect(state.expandedID == a)
        #expect(state.deletableID == nil)
        state.endEditing()
        #expect(state.toggleExpanded(b))
        #expect(state.deletableID == b)
    }

    @Test func onlyExpandedRowCanBeEdited() {
        var state = BoardState()
        #expect(!state.beginEditing(a))
        state.toggleExpanded(a)
        #expect(!state.beginEditing(b))
        #expect(state.beginEditing(a))
        #expect(!state.beginEditing(a))
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
        #expect(state.reconcile(existing: [a, c]) == [a])
        #expect(state.highlightedIDs == [a])
        // 之后 b 也到了
        #expect(state.reconcile(existing: [a, b, c]) == [b])
        #expect(state.highlightedIDs == [a, b])
        // 再刷新不重复开始
        #expect(state.reconcile(existing: [a, b, c]).isEmpty)
    }

    @Test func highlightExpires() {
        var state = BoardState()
        state.requestHighlight([a])
        let started = state.reconcile(existing: [a])
        state.expireHighlight(started)
        #expect(state.highlightedIDs.isEmpty)
        // 过期后刷新不会再次高亮
        #expect(state.reconcile(existing: [a]).isEmpty)
    }

    @Test func newRequestReplacesOldOne() {
        var state = BoardState()
        state.requestHighlight([a])
        state.reconcile(existing: [a, b])
        state.requestHighlight([b])
        #expect(state.highlightedIDs.isEmpty)
        #expect(state.reconcile(existing: [a, b]) == [b])
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
