import SwiftUI

extension ContentView {
    func scheduleFaviconPrefetch(for results: [BrowserSearchResult]) {
        faviconPrefetchDebounceTask?.cancel()
        let snapshot = results
        // Expanding "show all tabs" reveals rows beyond the collapsed-view cap;
        // fetch every one of them instead of leaving the tail without favicons.
        let prefetchLimit = isShowingAllOpenTabs ? results.count : (searchText.isEmpty ? effectiveQuickOpenLimit : 12)

        faviconPrefetchDebounceTask = Task {
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                appState.browserService.preloadFavicons(for: snapshot, limit: prefetchLimit)
            }
        }
    }

    func scheduleSearchFetch() {
        searchDebounceTask?.cancel()
        let query = effectiveQueryString()
        let filter = ScopeFilter.from(chips: scopeChips)
        searchDebounceTask = Task {
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                appState.browserService.fetchResults(matching: query, filter: filter)
            }
        }
    }

    /// Immediate (un-debounced) fetch using the current chip + query state.
    func triggerFetch() {
        searchDebounceTask?.cancel()
        let query = effectiveQueryString()
        let filter = ScopeFilter.from(chips: scopeChips)
        appState.browserService.fetchResults(matching: query, filter: filter)
    }

    /// The free-text query portion (excludes any in-progress `in:` token, which
    /// hasn't been committed to a chip yet and shouldn't be sent to the backend).
    private func effectiveQueryString() -> String {
        switch scopeSuggestionMode {
        case .hidden: return searchText
        case .root(_, let range), .bookmarks(_, let range), .history(_, let range):
            var copy = searchText
            copy.removeSubrange(range)
            return copy.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    var isScopeDropdownVisible: Bool {
        switch scopeSuggestionMode {
        case .hidden: return false
        case .root: return !currentScopeSuggestions().isEmpty
        // Drill-down modes always show the dropdown so an empty-folders state
        // is visible instead of silently disappearing.
        case .bookmarks, .history: return true
        }
    }

    var scopeDropdownEmptyStateText: String? {
        switch scopeSuggestionMode {
        case .bookmarks:
            return appState.browserService.cachedBookmarks.isEmpty
                ? "Loading bookmarks…"
                : "No matching folders"
        case .history:
            return "No matching time range"
        default:
            return nil
        }
    }

    func currentScopeSuggestions() -> [ScopeSuggestion] {
        switch scopeSuggestionMode {
        case .hidden:
            return []
        case .root(let prefix, _):
            let trimmed = prefix.lowercased()
            var items: [ScopeSuggestion] = [
                .root(.duplicate),
                .root(.bookmarks),
                .root(.history),
                // Non-browser sources. Always listed (per design), even when
                // no Finder window is open — it's a stable category, not an
                // instance.
                .root(.source(name: "Finder"))
            ]
            for window in appState.browserService.availableWindows {
                items.append(.root(.window(window)))
            }
            if trimmed.isEmpty { return items }
            return items.filter { $0.label.lowercased().contains(trimmed) }
        case .bookmarks(let prefix, _):
            let trimmed = prefix.lowercased()
            let folders = appState.browserService.availableBookmarkFolders.map(ScopeSuggestion.bookmarkFolder)
            if trimmed.isEmpty { return folders }
            return folders.filter {
                $0.label.lowercased().contains(trimmed)
                    || ($0.detail ?? "").lowercased().contains(trimmed)
            }
        case .history(let prefix, _):
            let trimmed = prefix.lowercased()
            let times = HistoryTimeScope.allCases.map(ScopeSuggestion.historyTime)
            if trimmed.isEmpty { return times }
            return times.filter { $0.label.lowercased().contains(trimmed) }
        }
    }

    func recomputeScopeSuggestionMode() {
        let newMode = ScopeSuggestionParser.mode(for: searchText)

        // Auto-commit drill-down parent when the user's typed prefix matches no
        // child suggestion. Picking `@Bookmarks:foo` commits `[Bookmarks]` and
        // leaves `foo` as free text. Only fires while drilling (root mode keeps
        // its empty state).
        if autoCommitDrillDownParentIfNeeded(for: newMode) {
            return
        }

        if newMode != scopeSuggestionMode {
            scopeSuggestionMode = newMode
            scopeDropdownSelectedIndex = 0
        } else {
            let count = currentScopeSuggestions().count
            if count == 0 {
                scopeDropdownSelectedIndex = 0
            } else if scopeDropdownSelectedIndex >= count {
                scopeDropdownSelectedIndex = count - 1
            }
        }
    }

    /// If the user is drilling into `@Bookmarks:` or `@History:` and has typed
    /// a non-empty prefix that matches no child option, commit the plain parent
    /// chip and let the prefix continue as free-text search. Returns true when
    /// it fired (caller should bail out of further mode handling).
    private func autoCommitDrillDownParentIfNeeded(for mode: ScopeSuggestionMode) -> Bool {
        switch mode {
        case .bookmarks(let prefix, let range):
            let trimmed = prefix.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return false }
            let lower = trimmed.lowercased()
            let folders = appState.browserService.availableBookmarkFolders
            let anyMatch = folders.contains {
                $0.displayName.lowercased().contains(lower)
                    || $0.folderPath.lowercased().contains(lower)
            }
            guard !anyMatch else { return false }
            commitDrillDownParent(parent: .bookmarks, keepingFreeText: prefix, tokenRange: range)
            return true
        case .history(let prefix, let range):
            let trimmed = prefix.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return false }
            let lower = trimmed.lowercased()
            let anyMatch = HistoryTimeScope.allCases.contains { $0.label.lowercased().contains(lower) }
            guard !anyMatch else { return false }
            commitDrillDownParent(parent: .historyAll, keepingFreeText: prefix, tokenRange: range)
            return true
        default:
            return false
        }
    }

    private enum DrillDownParent { case bookmarks, historyAll }

    private func commitDrillDownParent(
        parent: DrillDownParent,
        keepingFreeText prefix: String,
        tokenRange: Range<String.Index>
    ) {
        // Suppress the searchText onChange that our own replaceToken triggers —
        // we've already moved to a chip-committed state; the recomputeScope...
        // call below re-syncs without recursing.
        suppressNextSearchChange = true
        replaceToken(at: tokenRange, with: prefix)
        switch parent {
        case .bookmarks:
            appendChip(.init(kind: .bookmarks))
        case .historyAll:
            appendChip(.init(kind: .history(nil)))
        }
        scopeSuggestionMode = .hidden
        scopeDropdownSelectedIndex = 0
        triggerFetch()
        isSearchFocused = true
    }

    func moveScopeSuggestionSelection(by delta: Int) {
        let count = currentScopeSuggestions().count
        guard count > 0 else { return }
        scopeDropdownSelectedIndex = (scopeDropdownSelectedIndex + delta + count) % count
    }

    func commitScopeSuggestion(_ suggestion: ScopeSuggestion) {
        let tokenRange: Range<String.Index>?
        switch scopeSuggestionMode {
        case .hidden: tokenRange = nil
        case .root(_, let range), .bookmarks(_, let range), .history(_, let range):
            tokenRange = range
        }

        // Handle drill-down: picking `Bookmarks` or `History` from root replaces
        // the token with `@Bookmarks:` / `@History:` so the dropdown stays open.
        if case .root(let rootSugg) = suggestion {
            switch rootSugg {
            case .bookmarks:
                // Always drill into folder picker; the dropdown handles the
                // empty-folders state. Cold caches will populate via the
                // ambient refresh triggered by the scoped fetch.
                replaceToken(at: tokenRange, with: "@Bookmarks:")
                recomputeScopeSuggestionMode()
                return
            case .history:
                replaceToken(at: tokenRange, with: "@History:")
                recomputeScopeSuggestionMode()
                return
            case .duplicate:
                replaceToken(at: tokenRange, with: "")
                appendChip(.init(kind: .duplicate))
            case .window(let ref):
                replaceToken(at: tokenRange, with: "")
                appendChip(.init(kind: .window(ref)))
            case .source(let name):
                replaceToken(at: tokenRange, with: "")
                appendChip(.init(kind: .source(name)))
            }
        } else if case .bookmarkFolder(let ref) = suggestion {
            replaceToken(at: tokenRange, with: "")
            appendChip(.init(kind: .bookmarksFolder(ref)))
        } else if case .historyTime(let time) = suggestion {
            replaceToken(at: tokenRange, with: "")
            appendChip(.init(kind: .history(time)))
        }

        recomputeScopeSuggestionMode()
        triggerFetch()
        isSearchFocused = true
    }

    /// Entry point for the tappable duplicate-count tag in the footer status
    /// line. Behaves like typing `@duplicate` from scratch — clears any
    /// existing text/chips first rather than stacking onto them, since a
    /// stacked `@Bookmarks` + `@duplicate` combination would always be empty
    /// (bookmarks aren't live tabs).
    func activateDuplicateFilterFromTag() {
        searchText = ""
        scopeChips = []
        activeSearchAlias = nil
        consumedAliasKeyword = ""
        rejectedAliasKeyword = nil
        focusedChipID = nil
        commitScopeSuggestion(.root(.duplicate))
    }

    private func replaceToken(at range: Range<String.Index>?, with replacement: String) {
        guard let range else {
            searchText = replacement
            return
        }
        var text = searchText
        text.replaceSubrange(range, with: replacement)
        // Trim trailing whitespace if the chip eats the whole token, leaving "react in:foo" → "react ".
        if replacement.isEmpty {
            while text.hasSuffix(" ") { text.removeLast() }
        }
        searchText = text
    }

    private func appendChip(_ chip: ScopeChip) {
        // Stackable per design — duplicate chips in the same bucket are allowed
        // (redundant AND). User removes via backspace if unwanted.
        scopeChips.append(chip)
    }

    /// Removes the named chip and shifts keyboard focus sensibly: prefer the
    /// chip just to the left of the removed one, falling back to clearing focus
    /// (which returns the caret to the input field).
    func removeChip(id: UUID) {
        guard let idx = scopeChips.firstIndex(where: { $0.id == id }) else { return }
        scopeChips.remove(at: idx)
        if scopeChips.isEmpty {
            focusedChipID = nil
        } else if idx > 0 {
            focusedChipID = scopeChips[idx - 1].id
        } else {
            focusedChipID = nil
        }
        isSearchFocused = focusedChipID == nil
        triggerFetch()
    }

    /// Gmail-style two-step delete: first backspace at empty input focuses the
    /// last chip; the next backspace (while a chip is focused) removes it.
    func handleBackspaceAtEmptyInput() {
        guard !scopeChips.isEmpty else { return }
        if let focusedChipID {
            removeChip(id: focusedChipID)
        } else {
            focusedChipID = scopeChips.last?.id
        }
    }

    /// Left-arrow at empty input enters the chip strip from the right and walks
    /// further leftward through chips on each subsequent press.
    func handleLeftArrowAtEmptyInput() {
        guard !scopeChips.isEmpty else { return }
        if let current = focusedChipID,
           let idx = scopeChips.firstIndex(where: { $0.id == current }),
           idx > 0 {
            focusedChipID = scopeChips[idx - 1].id
        } else if focusedChipID == nil {
            focusedChipID = scopeChips.last?.id
        }
    }

    func handleScopeDropdownEnter() -> Bool {
        let suggestions = currentScopeSuggestions()
        guard !suggestions.isEmpty,
              suggestions.indices.contains(scopeDropdownSelectedIndex) else { return false }
        commitScopeSuggestion(suggestions[scopeDropdownSelectedIndex])
        return true
    }

    func dismissScopeDropdown() {
        // Drop the in-progress `in:...` token entirely.
        if case .root(_, let range) = scopeSuggestionMode {
            replaceToken(at: range, with: "")
        } else if case .bookmarks(_, let range) = scopeSuggestionMode {
            replaceToken(at: range, with: "")
        } else if case .history(_, let range) = scopeSuggestionMode {
            replaceToken(at: range, with: "")
        }
        scopeSuggestionMode = .hidden
        scopeDropdownSelectedIndex = 0
    }

    func resetForCommandBarOpen() {
        searchDebounceTask?.cancel()
        suppressNextSearchChange = true
        searchText = ""
        isShowingAllOpenTabs = appState.wasOpenedByMouse
        activeSearchAlias = nil
        consumedAliasKeyword = ""
        rejectedAliasKeyword = nil
        appState.isSearchTextEmpty = true
        appState.resetTypingActivity()
        scopeChips = []
        scopeSuggestionMode = .hidden
        scopeDropdownSelectedIndex = 0
        focusedChipID = nil
        appState.selectedIndex = -1
        hasCycled = false
        lastInteractionKey = .none
        if appState.wasOpenedByHover || wasOpenedByHover {
            viewStore.resetForHoverOpen()
        } else if let initial = appState.pendingInitialView {
            viewStore.resetForOpen(to: initial)
            appState.pendingInitialView = nil
        } else {
            viewStore.resetForOpen()
        }
        flickDetector.reset()
        if appState.browserService.hasFetchedOpenTabCount {
            myOrderStore.reconcile(liveTabs: appState.browserService.cachedLiveTabs)
        }
        let store = ShortcutStore.shared
        let shortcutMods = store.modifiers.intersection(.deviceIndependentFlagsMask)
        let currentMods = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
        isShortcutModifierHeld = !currentMods.intersection(shortcutMods).isEmpty
        clearKeyboardSwipe()
        clearPointerSwipeSuppression()
        resetPointerSwipe(animated: false)
        toastDismissTask?.cancel()
        toastMessage = nil
    }
}
