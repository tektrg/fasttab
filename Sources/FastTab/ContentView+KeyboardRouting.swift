import SwiftUI
import AppKit
import IndieCommandBar

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
            // Custom pages ignore the (preserved) Recents search text; the New
            // View page's Return is its "Create View" button.
            if viewStore.activeView == .newView {
                env.customViewEditor.presentNew()
            } else if viewStore.activeView.isCustomPage {
                // Nothing selected on a custom view: no-op.
            } else if let activeSearchAlias {
                activateSearchAlias(alias: activeSearchAlias, query: searchText)
            } else if !searchText.isEmpty, displayedResults.isEmpty {
                activateSearchTheWeb(query: searchText)
            }
            return
        }

        let item = items[appState.selectedIndex]
        switch item {
        case .result(let result):
            activateAndHide(result)
        case .orderedEntry(let slot):
            activateOrderedSlot(slot)
        case .showAllTabs, .searchTheWeb, .searchAliasHint, .searchAliasQuery:
            activateExtraRow(item)
        }
    }

    /// What clicking or pressing Return on one of Fast Tab's extra rows does.
    func activateExtraRow(_ item: CommandBarDisplayItem) {
        switch item {
        case .result, .orderedEntry:
            return
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
        let store = env.searchAliasStore
        let triggerKey: SearchAliasTriggerKey
        switch keyCode {
        case FastTabKeyRouting.tabKeyCode: triggerKey = .tab
        case FastTabKeyRouting.spaceKeyCode: triggerKey = .space
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

    /// "Choose Another" on the shortcut-conflict banner: hide the bar and
    /// open Settings on the Shortcuts tab.
    func openShortcutSettings() {
        dismissCommandBar()
        env.openSettingsPane(.shortcuts, openSettings)
    }

    func moveSelectionForward(includeSearchField: Bool) {
        moveSelection(forward: true, includeSearchField: includeSearchField)
    }

    func moveSelectionBackward(includeSearchField: Bool) {
        moveSelection(forward: false, includeSearchField: includeSearchField)
    }

    private func moveSelection(forward: Bool, includeSearchField: Bool) {
        clearKeyboardSwipe()
        resetPointerSwipe(animated: true)
        isSearchFocused = appState.commandBar.moveSelection(
            forward ? .forward : .backward,
            itemCount: displayedItems.count,
            includeSearchField: includeSearchField
        )
    }

    /// Connects the shared cycle session to this view: each hotkey tap moves the
    /// selection (⇧ + hotkey moves back), releasing the modifier activates it.
    func wireCycleSession() {
        cycleSession.onAdvance = { direction in
            moveSelection(forward: direction == .forward, includeSearchField: true)
            return appState.selectedIndex != -1
        }
        cycleSession.onCommit = {
            activateSelectedDisplayItem()
        }
    }

    private func hideBarFromEscape() {
        appState.hideCommandBar()
        cycleSession.reset()
        clearKeyboardSwipe()
        resetPointerSwipe(animated: false)
    }

    private func clearSelectionFromEscape() {
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
                // The view builder's form scrolls; no page swipes under it.
                if customViewEditorHoldsBar { return event }
                return handlePointerScrollSwipe(event) ? nil : event
            } else if event.type == .keyDown {
                // Hidden bar: keys belong to whatever window is key (Settings
                // text fields — e.g. the Views sheet — need Space/arrows/Return).
                guard appState.isVisible else { return event }
                appState.recordTypingActivity()
                let action = FastTabKeyRouting.route(
                    keyCode: event.keyCode,
                    characters: event.charactersIgnoringModifiers ?? "",
                    modifiers: event.modifierFlags,
                    context: keyRoutingContext(keyCode: event.keyCode),
                    hooks: keyRoutingHooks(event)
                )
                return perform(action, keyCode: event.keyCode) ? nil : event
            } else if event.type == .flagsChanged && appState.isVisible {
                cycleSession.handleFlagsChanged(event.modifierFlags)
            }
            return event
        }
    }

    // MARK: - Key routing glue

    private func keyRoutingContext(keyCode: UInt16) -> FastTabKeyRouting.Context {
        let items = displayedItems
        var row = FastTabKeyRouting.SelectedRow.none
        if items.indices.contains(appState.selectedIndex) {
            let item = items[appState.selectedIndex]
        switch item {
            case .orderedEntry: row = .stackSlot
            case .result(let result): row = result.type == .tab ? .liveTab : .otherResult
            default: row = .other
            }
        }
        return FastTabKeyRouting.Context(
            isVisible: appState.isVisible,
            selectedIndex: appState.selectedIndex,
            selectedRow: row,
            searchTextIsEmpty: searchText.isEmpty,
            isAliasActive: activeSearchAlias != nil,
            aliasCommittableByKey: aliasCommittableBy(keyCode: keyCode) != nil,
            hasScopeChips: !scopeChips.isEmpty,
            isScopeDropdownVisible: isScopeDropdownVisible,
            isChipFocused: focusedChipID != nil,
            isStackActive: viewStore.activeView == .stack,
            stackPinnedCount: stackPinnedSlots.count,
            cycleShortcuts: cycleShortcuts(),
            hasTextSelection: CommandBarKeyRouter.keyWindowHasTextSelection()
        )
    }

    /// Mirrors `AppDelegate.handleGlobalShortcut`: which global shortcuts' taps cycle right now.
    private func cycleShortcuts() -> [FastTabKeyRouting.CycleShortcut] {
        let store = ShortcutStore.shared
        var shortcuts = [FastTabKeyRouting.CycleShortcut(keyCode: store.keyCode, modifiers: store.modifiers)]
        if viewStore.activeView == .recents, let recents = store.recentsShortcut {
            shortcuts.append(.init(keyCode: recents.keyCode, modifiers: recents.modifierFlags))
        }
        if viewStore.activeView == .stack, let stack = store.stackShortcut {
            shortcuts.append(.init(keyCode: stack.keyCode, modifiers: stack.modifierFlags))
        }
        return shortcuts
    }

    private func keyRoutingHooks(_ event: NSEvent) -> FastTabKeyRouting.Hooks {
        let userModifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .intersection([.command, .option, .control, .shift])
        return FastTabKeyRouting.Hooks(
            customViewEditor: { routeCustomViewEditorKey(event, modifiers: userModifiers) },
            selectNumberedView: { viewStore.selectNumberedView($0) },
            listShortcut: { handleFastTabListShortcut(keyCode: $0) },
            scopeDropdownEnter: { handleScopeDropdownEnter() }
        )
    }

    /// Performs a routed key. Returns true when the event is consumed.
    private func perform(_ action: FastTabKeyRouting.Action, keyCode: UInt16) -> Bool {
        let items = displayedItems
        let selected = items.indices.contains(appState.selectedIndex) ? items[appState.selectedIndex] : nil
        switch action {
        case .passThrough:
            return false
        case .consumed:
            return true
        case .togglePinStackSlot:
            if case .orderedEntry(let slot)? = selected { myOrderStore.togglePinSlot(slot.slotID) }
        case .togglePinTab:
            if case .result(let result)? = selected { appState.browserService.togglePin(result) }
        case .closeStackSlot:
            if case .orderedEntry(let slot)? = selected { myOrderStore.closeSlot(slot.slotID) }
        case .removeTab:
            if case .result(let result)? = selected { performRemove(result) }
        case .reorderStack(let up):
            let index = appState.selectedIndex
            myOrderStore.reorderSlot(from: index, to: up ? index - 1 : index + 1)
            appState.selectedIndex += up ? -1 : 1
        case .exitAliasMode:
            exitSearchAliasMode()
        case .backspaceIntoChips:
            handleBackspaceAtEmptyInput()
        case .commitAlias:
            if let alias = aliasCommittableBy(keyCode: keyCode) { commitSearchAlias(alias) }
        case .dismissScopeDropdown:
            dismissScopeDropdown()
        case .unfocusChip:
            focusedChipID = nil
            isSearchFocused = true
        case .moveScopeSuggestion(let delta):
            moveScopeSuggestionSelection(by: delta)
        case .moveSelection(let forward, let via):
            moveSelection(forward: forward, includeSearchField: true)
            lastInteractionKey = via
        case .keyboardSwipe(let swipe):
            handleKeyboardSwipe(swipe)
            lastInteractionKey = .leftRight
        case .activateSelection:
            activateSelectedDisplayItem()
        case .clearSelection:
            clearSelectionFromEscape()
        case .hideBar:
            hideBarFromEscape()
        case .cycleBackward:
            cycleSession.advance(.backward)
        case .copySelection:
            switch selected {
            case .result(let result)?: performCopyLink(result)
            case .orderedEntry(let slot)?: performCopySlotURL(slot)
            default: return false
            }
        case .openSettings:
            // Same as the bar's gear button.
            openSettings()
        }
        return true
    }
}
