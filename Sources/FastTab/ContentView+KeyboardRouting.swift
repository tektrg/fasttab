import SwiftUI
import AppKit

private let kSpaceKeyCode: UInt16 = 49
private let kEnterKeyCode: UInt16 = 36
private let kDeleteKeyCode: UInt16 = 51
private let kTabKeyCode: UInt16 = 48
private let kEscapeKeyCode: UInt16 = 53
private let kLeftArrowKeyCode: UInt16 = 123
private let kRightArrowKeyCode: UInt16 = 124
private let kUpArrowKeyCode: UInt16 = 126
private let kDownArrowKeyCode: UInt16 = 125

extension ContentView {
    func activateAndHide(_ result: BrowserSearchResult) {
        clearKeyboardSwipe()
        clearPointerSwipeSuppression()
        resetPointerSwipe(animated: false)
        appState.browserService.activate(result)
        appState.hideCommandBar()
    }

    func activateSearchTheWeb(query: String) {
        clearKeyboardSwipe()
        clearPointerSwipeSuppression()
        resetPointerSwipe(animated: false)
        appState.browserService.openWebSearch(query: query)
        appState.hideCommandBar()
    }

    private func activateSelectedDisplayItem() {
        let items = displayedItems
        guard items.indices.contains(appState.selectedIndex) else {
            // No selection to activate — typically because the fetch for this
            // query is still in flight (results stay empty/stale until it
            // resolves), which would otherwise force the user to wait out the
            // debounce before Enter did anything. If there's nothing to show
            // yet, don't make them wait: search immediately.
            // Alias mode is an explicit commitment, so Enter belongs to it even
            // before anything is typed (opens the site's search page) and even
            // when no row is highlighted.
            if let activeSearchAlias {
                activateSearchAlias(alias: activeSearchAlias, query: searchText)
            } else if !searchText.isEmpty, displayedResults.isEmpty {
                activateSearchTheWeb(query: searchText)
            }
            return
        }

        switch items[appState.selectedIndex] {
        case .result(let result):
            activateAndHide(result)
        case .orderedEntry(let slot):
            activateOrderedSlot(slot)
        case .bookmarkRow(let row):
            switch row {
            case .folder(let id, _, _, _, _, _):
                bookmarkTreeStore.toggleFolder(id)
            case .bookmark(let item, _, let liveTab, _, let isDeleting):
                guard !isDeleting else { return }
                if let liveTab {
                    activateAndHide(liveTab)
                } else {
                    activateAndHide(item.asSearchResult)
                }
            }
        case .showAllTabs:
            expandAllOpenTabs()
        case .searchTheWeb(let query):
            activateSearchTheWeb(query: query)
        case .searchAliasHint(let alias):
            commitSearchAlias(alias)
        case .searchAliasQuery(let alias, let query):
            activateSearchAlias(alias: alias, query: query)
        }
    }

    func activateOrderedSlot(_ slot: OrderedTabSlot) {
        switch slot.state {
        case .live:
            activateAndHide(slot.asSearchResult)
        case .ghost:
            dismissCommandBar()
            myOrderStore.reopenSlot(slot.slotID)
        case .browserFrozen:
            if let url = URL(string: slot.url) {
                NSWorkspace.shared.open(url)
                dismissCommandBar()
            }
        }
    }

    // MARK: - Search aliases

    /// Enters alias mode: the keyword is consumed out of the input and shown as
    /// a badge, mirroring how a browser's address bar turns a matched keyword
    /// into a search-engine chip.
    func commitSearchAlias(_ alias: SearchAlias) {
        activeSearchAlias = alias
        consumedAliasKeyword = searchText
        rejectedAliasKeyword = nil
        // Synchronously notify AppState that search is active so the hover-dismiss
        // monitor doesn't see a momentary empty-field gap before the view's onChange fires.
        appState.isSearchTextEmpty = false
        // Clearing the text re-runs `handleSearchTextChange`, which puts the
        // selection back on the search field — correct here, since the user is
        // about to type the query. Enter still reaches the alias: the Enter
        // handler checks alias mode before it needs a highlighted row.
        searchText = ""
        isSearchFocused = true
    }

    /// Leaves alias mode and puts the consumed keyword back in the field.
    ///
    /// Restoring matters because entering alias mode is easy to do by accident:
    /// any ordinary search whose first word happens to be a keyword commits the
    /// alias the moment Space is pressed. Without the restore, that mistake
    /// costs the user the whole word they had typed.
    ///
    /// The keyword is also remembered as rejected, so pressing Space again on
    /// the restored text types a space instead of re-entering the mode the user
    /// just left — otherwise backing out and continuing to type is a loop.
    func exitSearchAliasMode() {
        guard activeSearchAlias != nil else { return }
        activeSearchAlias = nil
        if !consumedAliasKeyword.isEmpty {
            rejectedAliasKeyword = consumedAliasKeyword.lowercased()
            // Deliberately *not* suppressed: restoring the text must re-run the
            // normal search-text handling so results reflect the keyword again
            // rather than whatever the alias-mode query last fetched.
            searchText = consumedAliasKeyword
            consumedAliasKeyword = ""
        }
        appState.isSearchTextEmpty = isSearchEmpty
        appState.selectedIndex = -1
        isSearchFocused = true
    }

    func activateSearchAlias(alias: SearchAlias, query: String) {
        clearKeyboardSwipe()
        resetPointerSwipe(animated: false)
        appState.browserService.openSearchAlias(alias, query: query)
        activeSearchAlias = nil
        appState.hideCommandBar()
    }

    /// True when `keyCode` is a trigger the user has left enabled and the
    /// current text exactly names an alias.
    private func aliasCommittableBy(keyCode: UInt16) -> SearchAlias? {
        let store = SearchAliasStore.shared
        let triggerKey: SearchAliasTriggerKey
        switch keyCode {
        case kTabKeyCode: triggerKey = .tab
        case kSpaceKeyCode: triggerKey = .space
        default: return nil
        }
        guard store.isTriggerEnabled(triggerKey) else { return nil }
        // Don't re-grab a keyword the user just backed out of.
        guard searchText.lowercased() != rejectedAliasKeyword else { return nil }
        return store.alias(committedBy: searchText)
    }

    func expandAllOpenTabs() {
        guard searchText.isEmpty else { return }
        clearKeyboardSwipe()
        resetPointerSwipe(animated: false)
        withAnimation(.spring(response: 0.24, dampingFraction: 0.88)) {
            isShowingAllOpenTabs = true
        }
        scheduleFaviconPrefetch(for: displayedResults)
    }

    func dismissCommandBar() {
        toastDismissTask?.cancel()
        toastMessage = nil
        clearKeyboardSwipe()
        clearPointerSwipeSuppression()
        resetPointerSwipe(animated: false)
        appState.hideCommandBar()
        cycleSession.reset()
    }

    func moveSelectionForward(includeSearchField: Bool) {
        clearKeyboardSwipe()
        resetPointerSwipe(animated: true)
        let items = displayedItems
        let minimumIndex = includeSearchField ? -1 : 0

        if items.isEmpty {
            appState.selectedIndex = minimumIndex
            isSearchFocused = includeSearchField
            return
        }

        let maximumIndex = items.count - 1
        if appState.selectedIndex < minimumIndex || appState.selectedIndex >= maximumIndex {
            appState.selectedIndex = minimumIndex
        } else {
            appState.selectedIndex += 1
        }

        isSearchFocused = includeSearchField && appState.selectedIndex == -1
    }

    func moveSelectionBackward(includeSearchField: Bool) {
        clearKeyboardSwipe()
        resetPointerSwipe(animated: true)
        let items = displayedItems
        let minimumIndex = includeSearchField ? -1 : 0

        if items.isEmpty {
            appState.selectedIndex = minimumIndex
            isSearchFocused = includeSearchField
            return
        }

        let maximumIndex = items.count - 1
        if appState.selectedIndex <= minimumIndex || appState.selectedIndex > maximumIndex {
            appState.selectedIndex = maximumIndex
        } else {
            appState.selectedIndex -= 1
        }

        isSearchFocused = includeSearchField && appState.selectedIndex == -1
    }

    /// Connects the shared cycle session to this view: each hotkey tap moves the
    /// selection, releasing the modifier activates it.
    func wireCycleSession() {
        cycleSession.onAdvance = {
            moveSelectionForward(includeSearchField: true)
            return appState.selectedIndex != -1
        }
        cycleSession.onCommit = {
            activateSelectedDisplayItem()
        }
    }

    private func handleEscapeKey() {
        if bookmarkTreeStore.armedBookmarkID != nil {
            bookmarkTreeStore.armedBookmarkID = nil
            return
        }

        if appState.selectedIndex == -1 {
            appState.hideCommandBar()
            cycleSession.reset()
            clearKeyboardSwipe()
            resetPointerSwipe(animated: false)
            return
        }

        appState.selectedIndex = -1
        isSearchFocused = true
        cycleSession.reset()
        clearKeyboardSwipe()
        resetPointerSwipe(animated: true)
    }

    func setupLocalMonitor() {
        wireCycleSession()
        guard localMonitor == nil else { return }
        let monitoredEvents: NSEvent.EventTypeMask = [
            .keyDown,
            .flagsChanged,
            .scrollWheel
        ]

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: monitoredEvents) { event in
            if appState.isRecordingShortcut { return event }

            if event.type == .scrollWheel {
                return handlePointerScrollSwipe(event) ? nil : event
            } else if event.type == .keyDown {
                if appState.isVisible {
                    appState.recordTypingActivity()
                }
                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                let userModifiers = flags.intersection([.command, .option, .control, .shift])

                let noModifiers = userModifiers.isEmpty

                // ⌘1/2/3 view switching: must be guarded on isVisible so Settings doesn't swallow them.
                if appState.isVisible, userModifiers == [.command] {
                    switch event.keyCode {
                    case 18:
                        viewStore.selectView(.recents)
                        return nil
                    case 19:
                        viewStore.selectView(.myOrder)
                        return nil
                    case 20:
                        viewStore.selectView(.bookmarks)
                        return nil
                    default:
                        break
                    }
                }

                // ⌘P: toggle pin on selected row (ordered entry or live tab result)
                if appState.isVisible, userModifiers == [.command], event.keyCode == 35 {
                    let items = displayedItems
                    if appState.selectedIndex >= 0, appState.selectedIndex < items.count {
                        switch items[appState.selectedIndex] {
                        case .orderedEntry(let slot):
                            myOrderStore.togglePinSlot(slot.slotID)
                            return nil
                        case .result(let result):
                            if result.type == .tab {
                                appState.browserService.togglePin(result)
                                return nil
                            }
                        default:
                            break
                        }
                    }
                }

                // ⌘W: close selected tab (ordered entry, live tab result, or open bookmark tab)
                if appState.isVisible, userModifiers == [.command], event.keyCode == 13 {
                    let items = displayedItems
                    if appState.selectedIndex >= 0, appState.selectedIndex < items.count {
                        switch items[appState.selectedIndex] {
                        case .orderedEntry(let slot):
                            myOrderStore.closeSlot(slot.slotID)
                            return nil
                        case .result(let result):
                            if result.type == .tab {
                                performRemove(result)
                                return nil
                            }
                        case .bookmarkRow(let row):
                            if case .bookmark(_, _, let liveTab, _, _) = row, let liveTab {
                                appState.browserService.remove(liveTab)
                                return nil
                            }
                        default:
                            break
                        }
                    }
                }

                // ⌥↑/⌥↓: reorder row in My Order (sent-link rows lead the list and never move)
                if appState.isVisible, userModifiers == [.option], viewStore.activeView == .myOrder, searchText.isEmpty {
                    let offset = myOrderSlotIndexOffset
                    let slotIdx = appState.selectedIndex - offset
                    if event.keyCode == 126 { // Up arrow
                        if slotIdx > 0 {
                            myOrderStore.reorderSlot(from: slotIdx, to: slotIdx - 1)
                            appState.selectedIndex -= 1
                            return nil
                        }
                    } else if event.keyCode == 125 { // Down arrow
                        if slotIdx >= 0, slotIdx < myOrderStore.slots.count - 1 {
                            myOrderStore.reorderSlot(from: slotIdx, to: slotIdx + 1)
                            appState.selectedIndex += 1
                            return nil
                        }
                    }
                }

                // Backspace at empty input: step-back into the chip strip,
                // then delete on the next press. Routed here (not via SwiftUI
                // `.onKeyPress(.delete)`) because that hook is unreliable when
                // the TextField is empty.
                // Alias badge sits closest to the caret, so it is what an
                // empty-input backspace removes first — before the chip strip.
                if noModifiers,
                   event.keyCode == kDeleteKeyCode,
                   appState.isVisible,
                   searchText.isEmpty,
                   activeSearchAlias != nil {
                    exitSearchAliasMode()
                    return nil
                }

                if noModifiers,
                   event.keyCode == kDeleteKeyCode,
                   appState.isVisible,
                   searchText.isEmpty,
                   !scopeChips.isEmpty {
                    handleBackspaceAtEmptyInput()
                    return nil
                }

                if noModifiers,
                   event.keyCode == kDeleteKeyCode,
                   appState.isVisible,
                   searchText.isEmpty,
                   appState.selectedIndex >= 0 {
                    let items = displayedItems
                    if appState.selectedIndex < items.count {
                        switch items[appState.selectedIndex] {
                        case .orderedEntry(let slot):
                            myOrderStore.closeSlot(slot.slotID)
                            return nil
                        case .bookmarkRow(let row):
                            if case .bookmark(let item, _, _, let isArmed, let isDeleting) = row {
                                guard !isDeleting else { return nil }
                                if isArmed {
                                    deleteBookmarkConfirmed(item)
                                } else {
                                    bookmarkTreeStore.armedBookmarkID = item.uniqueKey
                                }
                                return nil
                            }
                        case .result(let result):
                            if result.type == .tab {
                                performRemove(result)
                                return nil
                            }
                        default:
                            break
                        }
                    }
                }

                // Tab/Space commit a typed keyword into alias mode. Space only
                // ever reaches here with non-empty text, so it cannot collide
                // with the empty-input "space moves the selection" binding
                // handled further down.
                if noModifiers,
                   appState.isVisible,
                   !isScopeDropdownVisible,
                   activeSearchAlias == nil,
                   !searchText.isEmpty,
                   let alias = aliasCommittableBy(keyCode: event.keyCode) {
                    commitSearchAlias(alias)
                    return nil
                }

                if event.keyCode == kEscapeKeyCode && appState.isVisible {
                    if isScopeDropdownVisible {
                        dismissScopeDropdown()
                        return nil
                    }
                    if focusedChipID != nil {
                        focusedChipID = nil
                        isSearchFocused = true
                        return nil
                    }
                    handleEscapeKey()
                    return nil
                }

                if noModifiers && event.keyCode == kUpArrowKeyCode {
                    if isScopeDropdownVisible {
                        moveScopeSuggestionSelection(by: -1)
                        return nil
                    }
                    moveSelectionBackward(includeSearchField: true)
                    lastInteractionKey = .upDown
                    return nil
                }

                if noModifiers && event.keyCode == kDownArrowKeyCode {
                    if isScopeDropdownVisible {
                        moveScopeSuggestionSelection(by: 1)
                        return nil
                    }
                    moveSelectionForward(includeSearchField: true)
                    lastInteractionKey = .upDown
                    return nil
                }

                if noModifiers && event.keyCode == kLeftArrowKeyCode && appState.selectedIndex >= 0 {
                    let items = displayedItems
                    if appState.selectedIndex < items.count, case .bookmarkRow(let row) = items[appState.selectedIndex] {
                        if case .folder(let id, _, _, let isExpanded, _, _) = row, isExpanded {
                            bookmarkTreeStore.collapseFolder(id)
                        }
                        return nil
                    }
                    handleKeyboardSwipe(.delete)
                    lastInteractionKey = .leftRight
                    return nil
                }

                if noModifiers && event.keyCode == kRightArrowKeyCode && appState.selectedIndex >= 0 {
                    let items = displayedItems
                    if appState.selectedIndex < items.count, case .bookmarkRow(let row) = items[appState.selectedIndex] {
                        if case .folder(let id, _, _, let isExpanded, _, _) = row, !isExpanded {
                            bookmarkTreeStore.expandFolder(id)
                        }
                        return nil
                    }
                    handleKeyboardSwipe(.copy)
                    lastInteractionKey = .leftRight
                    return nil
                }

                let shiftOnly = userModifiers == .shift
                if event.keyCode == kSpaceKeyCode && (noModifiers || shiftOnly) && searchText.isEmpty {
                    if shiftOnly {
                        moveSelectionBackward(includeSearchField: true)
                    } else {
                        moveSelectionForward(includeSearchField: true)
                    }
                    lastInteractionKey = .space
                    return nil
                }

                if event.keyCode == kEnterKeyCode {
                    if isScopeDropdownVisible, handleScopeDropdownEnter() {
                        return nil
                    }
                    activateSelectedDisplayItem()
                    return nil
                }
            } else if event.type == .flagsChanged && appState.isVisible {
                cycleSession.handleFlagsChanged(event.modifierFlags)
            }
            return event
        }
    }
}
