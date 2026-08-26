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

    // MARK: - Search aliases

    /// Enters alias mode: the keyword is consumed out of the input and shown as
    /// a badge, mirroring how a browser's address bar turns a matched keyword
    /// into a search-engine chip.
    func commitSearchAlias(_ alias: SearchAlias) {
        activeSearchAlias = alias
        consumedAliasKeyword = searchText
        rejectedAliasKeyword = nil
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
        hasCycled = false
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

    func cycleShortcutSelectionForward() {
        moveSelectionForward(includeSearchField: true)
        hasCycled = appState.selectedIndex != -1
    }

    private func handleEscapeKey() {
        if appState.selectedIndex == -1 {
            appState.hideCommandBar()
            hasCycled = false
            clearKeyboardSwipe()
            resetPointerSwipe(animated: false)
            return
        }

        appState.selectedIndex = -1
        isSearchFocused = true
        hasCycled = false
        clearKeyboardSwipe()
        resetPointerSwipe(animated: true)
    }

    func setupLocalMonitor() {
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
                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                let userModifiers = flags.intersection([.command, .option, .control, .shift])

                let noModifiers = userModifiers.isEmpty

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
                    handleKeyboardSwipe(.delete)
                    lastInteractionKey = .leftRight
                    return nil
                }

                if noModifiers && event.keyCode == kRightArrowKeyCode && appState.selectedIndex >= 0 {
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
                let store = ShortcutStore.shared
                let shortcutMods = store.modifiers.intersection(.deviceIndependentFlagsMask)
                let currentMods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                let modifierReleased = currentMods.intersection(shortcutMods).isEmpty
                if modifierReleased {
                    isShortcutModifierHeld = false
                    if hasCycled {
                        activateSelectedDisplayItem()
                        hasCycled = false
                    }
                }
            }
            return event
        }
    }
}
