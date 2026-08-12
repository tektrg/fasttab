import SwiftUI
import AppKit

private let kSpaceKeyCode: UInt16 = 49
private let kEnterKeyCode: UInt16 = 36
private let kDeleteKeyCode: UInt16 = 51
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
            if !searchText.isEmpty, displayedResults.isEmpty {
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
        }
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
                if noModifiers,
                   event.keyCode == kDeleteKeyCode,
                   appState.isVisible,
                   searchText.isEmpty,
                   !scopeChips.isEmpty {
                    handleBackspaceAtEmptyInput()
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
