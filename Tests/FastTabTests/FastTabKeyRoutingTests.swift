import AppKit
import Foundation
import Testing
import IndieCommandBar
@testable import FastTab

/// Characterization of the bar's keyboard behavior (`FastTabKeyRouting`,
/// `ContentView+KeyboardRouting`). Written before the generic routing moved
/// into IndieCommandBar; these must keep passing unchanged.
@MainActor
struct FastTabKeyRoutingTests {
    typealias R = FastTabKeyRouting
    typealias Ctx = FastTabKeyRouting.Context

    private func route(_ keyCode: UInt16, _ modifiers: NSEvent.ModifierFlags = [], _ c: Ctx = Ctx(), hooks: R.Hooks = R.Hooks()) -> R.Action {
        R.route(keyCode: keyCode, modifiers: modifiers, context: c, hooks: hooks)
    }

    private func onRow(_ index: Int = 0, _ row: R.SelectedRow = .liveTab) -> Ctx {
        var c = Ctx()
        c.selectedIndex = index
        c.selectedRow = row
        return c
    }

    // MARK: Hidden bar

    @Test func hiddenBarPassesEveryKeyThrough() {
        var c = onRow()
        c.isVisible = false
        for key in [R.upArrowKeyCode, R.downArrowKeyCode, R.returnKeyCode, R.escapeKeyCode, R.spaceKeyCode] {
            #expect(route(key, [], c) == .passThrough)
        }
    }

    // MARK: Up / down

    @Test func arrowsMoveSelection() {
        #expect(route(R.downArrowKeyCode) == .moveSelection(forward: true, via: .upDown))
        #expect(route(R.upArrowKeyCode) == .moveSelection(forward: false, via: .upDown))
        #expect(route(R.downArrowKeyCode, [], onRow(2)) == .moveSelection(forward: true, via: .upDown))
    }

    @Test func arrowsWithModifiersAreNotMoves() {
        #expect(route(R.downArrowKeyCode, [.command]) == .passThrough)
        #expect(route(R.upArrowKeyCode, [.shift]) == .passThrough)
    }

    @Test func capsLockAndFunctionFlagsDoNotCountAsModifiers() {
        #expect(route(R.downArrowKeyCode, [.capsLock, .numericPad, .function]) == .moveSelection(forward: true, via: .upDown))
    }

    @Test func arrowsDriveTheScopeDropdownWhenOpen() {
        var c = Ctx()
        c.isScopeDropdownVisible = true
        #expect(route(R.downArrowKeyCode, [], c) == .moveScopeSuggestion(by: 1))
        #expect(route(R.upArrowKeyCode, [], c) == .moveScopeSuggestion(by: -1))
    }

    @Test func downFromSearchFieldGoesToFirstRowAndWrapsBack() {
        #expect(R.movedSelection(from: -1, forward: true, itemCount: 3, includeSearchField: true) == (0, false))
        #expect(R.movedSelection(from: 1, forward: true, itemCount: 3, includeSearchField: true) == (2, false))
        #expect(R.movedSelection(from: 2, forward: true, itemCount: 3, includeSearchField: true) == (-1, true))
    }

    @Test func upFromSearchFieldGoesToLastRow() {
        #expect(R.movedSelection(from: -1, forward: false, itemCount: 3, includeSearchField: true) == (2, false))
        #expect(R.movedSelection(from: 0, forward: false, itemCount: 3, includeSearchField: true) == (-1, true))
        #expect(R.movedSelection(from: 2, forward: false, itemCount: 3, includeSearchField: true) == (1, false))
    }

    @Test func staleSelectionSnapsBackIntoRange() {
        #expect(R.movedSelection(from: 9, forward: true, itemCount: 3, includeSearchField: true) == (-1, true))
        #expect(R.movedSelection(from: 9, forward: false, itemCount: 3, includeSearchField: true) == (2, false))
        #expect(R.movedSelection(from: -5, forward: true, itemCount: 3, includeSearchField: true) == (-1, true))
    }

    @Test func emptyListParksOnSearchField() {
        #expect(R.movedSelection(from: 0, forward: true, itemCount: 0, includeSearchField: true) == (-1, true))
        #expect(R.movedSelection(from: 0, forward: false, itemCount: 0, includeSearchField: false) == (0, false))
    }

    @Test func withoutSearchFieldSelectionWrapsWithinRows() {
        #expect(R.movedSelection(from: 2, forward: true, itemCount: 3, includeSearchField: false) == (0, false))
        #expect(R.movedSelection(from: 0, forward: false, itemCount: 3, includeSearchField: false) == (2, false))
    }

    // MARK: Cycle (hold modifier + tap): forward with the search field

    @Test func cycleAdvanceSteps() {
        // `wireCycleSession` advances like ↓ and reports whether a row is selected.
        let first = R.movedSelection(from: -1, forward: true, itemCount: 2, includeSearchField: true)
        #expect(first.index == 0)
        let wrapped = R.movedSelection(from: 1, forward: true, itemCount: 2, includeSearchField: true)
        #expect(wrapped.index == -1)
    }

    // MARK: Space

    @Test func spaceOnEmptyInputMovesSelection() {
        #expect(route(R.spaceKeyCode) == .moveSelection(forward: true, via: .space))
        #expect(route(R.spaceKeyCode, [.shift]) == .moveSelection(forward: false, via: .space))
    }

    @Test func spaceWithTextTypes() {
        var c = Ctx()
        c.searchTextIsEmpty = false
        #expect(route(R.spaceKeyCode, [], c) == .passThrough)
        #expect(route(R.spaceKeyCode, [.option]) == .passThrough)
    }

    // MARK: Left / right (keyboard swipe)

    @Test func leftRightSwipeOnlyWithARow() {
        #expect(route(R.leftArrowKeyCode, [], onRow()) == .keyboardSwipe(.delete))
        #expect(route(R.rightArrowKeyCode, [], onRow()) == .keyboardSwipe(.copy))
        #expect(route(R.leftArrowKeyCode) == .passThrough)
        #expect(route(R.rightArrowKeyCode) == .passThrough)
        #expect(route(R.leftArrowKeyCode, [.shift], onRow()) == .passThrough)
    }

    // MARK: Return

    @Test func returnActivatesWithAnyModifiers() {
        #expect(route(R.returnKeyCode) == .activateSelection)
        #expect(route(R.returnKeyCode, [], onRow()) == .activateSelection)
        #expect(route(R.returnKeyCode, [.command]) == .activateSelection)
    }

    @Test func returnGoesToScopeDropdownFirst() {
        var c = Ctx()
        c.isScopeDropdownVisible = true
        #expect(route(R.returnKeyCode, [], c, hooks: R.Hooks(scopeDropdownEnter: { true })) == .consumed)
        #expect(route(R.returnKeyCode, [], c, hooks: R.Hooks(scopeDropdownEnter: { false })) == .activateSelection)
        var asked = false
        _ = route(R.returnKeyCode, [], Ctx(), hooks: R.Hooks(scopeDropdownEnter: { asked = true; return true }))
        #expect(!asked)
    }

    // MARK: Esc order

    @Test func escapeClosesInnermostFirst() {
        var c = onRow()
        c.isAliasActive = true
        c.isScopeDropdownVisible = true
        c.isChipFocused = true
        #expect(route(R.escapeKeyCode, [], c) == .dismissScopeDropdown)
        c.isScopeDropdownVisible = false
        #expect(route(R.escapeKeyCode, [], c) == .unfocusChip)
        c.isChipFocused = false
        #expect(route(R.escapeKeyCode, [], c) == .clearSelection)
        c.selectedIndex = -1
        #expect(route(R.escapeKeyCode, [], c) == .hideBar)
    }

    @Test func escapeIgnoresModifiers() {
        #expect(route(R.escapeKeyCode, [.command]) == .hideBar)
        #expect(route(R.escapeKeyCode, [.shift], onRow()) == .clearSelection)
    }

    @Test func escapeInAliasModeDoesNotExitAlias() {
        // Alias mode is left by Backspace on empty input, not Esc.
        var c = Ctx()
        c.isAliasActive = true
        #expect(route(R.escapeKeyCode, [], c) == .hideBar)
    }

    // MARK: Aliases

    @Test func tabOrSpaceCommitsAMatchingKeyword() {
        var c = Ctx()
        c.searchTextIsEmpty = false
        c.aliasCommittableByKey = true
        #expect(route(R.tabKeyCode, [], c) == .commitAlias)
        #expect(route(R.spaceKeyCode, [], c) == .commitAlias)
        #expect(route(R.tabKeyCode, [.shift], c) == .passThrough)
        #expect(route(R.returnKeyCode, [], c) == .activateSelection)
    }

    @Test func aliasDoesNotCommitWhenBlocked() {
        var c = Ctx()
        c.searchTextIsEmpty = false
        c.aliasCommittableByKey = false
        #expect(route(R.tabKeyCode, [], c) == .passThrough)
        c.aliasCommittableByKey = true
        c.isAliasActive = true
        #expect(route(R.tabKeyCode, [], c) == .passThrough)
        c.isAliasActive = false
        c.isScopeDropdownVisible = true
        #expect(route(R.tabKeyCode, [], c) == .passThrough)
    }

    @Test func backspaceOnEmptyInputLeavesAliasThenChipsThenRow() {
        var c = onRow(0, .liveTab)
        c.isAliasActive = true
        c.hasScopeChips = true
        #expect(route(R.deleteKeyCode, [], c) == .exitAliasMode)
        c.isAliasActive = false
        #expect(route(R.deleteKeyCode, [], c) == .backspaceIntoChips)
        c.hasScopeChips = false
        #expect(route(R.deleteKeyCode, [], c) == .removeTab)
        c.selectedRow = .stackSlot
        #expect(route(R.deleteKeyCode, [], c) == .closeStackSlot)
        c.selectedRow = .otherResult
        #expect(route(R.deleteKeyCode, [], c) == .passThrough)
    }

    @Test func backspaceWithTextTypes() {
        var c = onRow()
        c.searchTextIsEmpty = false
        c.isAliasActive = true
        #expect(route(R.deleteKeyCode, [], c) == .passThrough)
    }

    // MARK: ⌘ shortcuts

    @Test func commandPAndWActOnTabsAndStackSlots() {
        #expect(route(R.pKeyCode, [.command], onRow(0, .liveTab)) == .togglePinTab)
        #expect(route(R.pKeyCode, [.command], onRow(0, .stackSlot)) == .togglePinStackSlot)
        #expect(route(R.pKeyCode, [.command], onRow(0, .otherResult)) == .passThrough)
        #expect(route(R.wKeyCode, [.command], onRow(0, .liveTab)) == .removeTab)
        #expect(route(R.wKeyCode, [.command], onRow(0, .stackSlot)) == .closeStackSlot)
        #expect(route(R.wKeyCode, [.command]) == .passThrough)
        #expect(route(R.pKeyCode, [.command, .shift], onRow()) == .passThrough)
    }

    @Test func commandSAndDGoToTheListBridge() {
        var seen: [UInt16] = []
        let hooks = R.Hooks(listShortcut: { seen.append($0); return $0 == 1 })
        #expect(route(1, [.command], onRow(), hooks: hooks) == .consumed)   // ⌘S
        #expect(route(2, [.command], onRow(), hooks: hooks) == .passThrough) // ⌘D refused
        #expect(seen == [1, 2])
        seen = []
        _ = route(1, [], onRow(), hooks: hooks)
        #expect(seen.isEmpty)
    }

    @Test func commandDigitsSwitchViews() {
        var asked: [Int] = []
        let hooks = R.Hooks(selectNumberedView: { asked.append($0); return $0 != 9 })
        #expect(route(18, [.command], Ctx(), hooks: hooks) == .consumed)
        #expect(route(25, [.command], Ctx(), hooks: hooks) == .passThrough)
        #expect(asked == [1, 9])
        #expect(route(18, [.command, .option], Ctx(), hooks: hooks) == .passThrough)
    }

    // MARK: ⌥↑/⌥↓ Stack reorder

    @Test func optionArrowsReorderPinnedStackRows() {
        var c = onRow(1, .stackSlot)
        c.isStackActive = true
        c.stackPinnedCount = 3
        #expect(route(R.upArrowKeyCode, [.option], c) == .reorderStack(up: true))
        #expect(route(R.downArrowKeyCode, [.option], c) == .reorderStack(up: false))
        c.selectedIndex = 0
        #expect(route(R.upArrowKeyCode, [.option], c) == .passThrough)
        c.selectedIndex = 2
        #expect(route(R.downArrowKeyCode, [.option], c) == .passThrough)
        c.selectedIndex = 1
        c.searchTextIsEmpty = false
        #expect(route(R.upArrowKeyCode, [.option], c) == .passThrough)
        c.searchTextIsEmpty = true
        c.isStackActive = false
        #expect(route(R.upArrowKeyCode, [.option], c) == .passThrough)
    }

    // MARK: View editor keys

    @Test func viewEditorRouteWinsOverEverything() {
        let consume = R.Hooks(customViewEditor: { .consume })
        let pass = R.Hooks(customViewEditor: { .passThrough })
        #expect(route(R.escapeKeyCode, [], onRow(), hooks: consume) == .consumed)
        #expect(route(R.downArrowKeyCode, [], onRow(), hooks: pass) == .passThrough)
        #expect(route(R.returnKeyCode, [], onRow(), hooks: pass) == .passThrough)
    }

    private func makePresenter(_ views: [CustomView] = []) -> (CustomViewEditorPresenter, CommandBarViewStore, () -> Void) {
        let (viewStore, store, cleanup) = CommandBarViewStoreTests.makeStore(customViews: views)
        return (CustomViewEditorPresenter(store: store, viewStore: viewStore), viewStore, cleanup)
    }

    @Test func editorNotShowingIsNotInvolved() {
        let (presenter, viewStore, cleanup) = makePresenter()
        defer { cleanup() }
        let r = CustomViewEditorKeyRoute.route(keyCode: R.escapeKeyCode, modifiers: [], presenter: presenter, activeView: viewStore.activeView)
        #expect(r == .notInvolved)
    }

    @Test func editorEscCancelsBuilderNotBar() {
        let (presenter, viewStore, cleanup) = makePresenter()
        defer { cleanup() }
        presenter.presentNew()
        let r = CustomViewEditorKeyRoute.route(keyCode: R.escapeKeyCode, modifiers: [], presenter: presenter, activeView: viewStore.activeView)
        #expect(r == .consume)
        #expect(presenter.request == nil)
    }

    @Test func editorTypingPassesThroughAndCommandReturnSaves() {
        let (presenter, viewStore, cleanup) = makePresenter()
        defer { cleanup() }
        presenter.presentNew()
        let active = viewStore.activeView
        for key in [R.downArrowKeyCode, R.returnKeyCode, R.tabKeyCode, R.spaceKeyCode] {
            #expect(CustomViewEditorKeyRoute.route(keyCode: key, modifiers: [], presenter: presenter, activeView: active) == .passThrough)
        }
        // Empty draft is invalid: ⌘Return beeps and keeps the builder.
        var beeps = 0
        let r = CustomViewEditorKeyRoute.route(keyCode: R.returnKeyCode, modifiers: [.command], presenter: presenter, activeView: active, beep: { beeps += 1 })
        #expect(r == .consume)
        #expect(beeps == 1)
        #expect(presenter.request == .new)
        // Keypad Enter counts as Return.
        _ = CustomViewEditorKeyRoute.route(keyCode: 76, modifiers: [.command], presenter: presenter, activeView: active, beep: { beeps += 1 })
        #expect(beeps == 2)
    }

    @Test func deleteConfirmCardSwallowsPlainKeysButNotCommandKeys() {
        let view = CustomView(name: "Work", iconName: "briefcase")
        let (presenter, viewStore, cleanup) = makePresenter([view])
        defer { cleanup() }
        presenter.requestDelete(id: view.id)
        let active = viewStore.activeView
        #expect(CustomViewEditorKeyRoute.route(keyCode: R.downArrowKeyCode, modifiers: [], presenter: presenter, activeView: active) == .consume)
        #expect(CustomViewEditorKeyRoute.route(keyCode: R.wKeyCode, modifiers: [.command], presenter: presenter, activeView: active) == .passThrough)
        #expect(CustomViewEditorKeyRoute.route(keyCode: R.escapeKeyCode, modifiers: [], presenter: presenter, activeView: active) == .consume)
        #expect(presenter.pendingDeleteID == nil)
    }
}
