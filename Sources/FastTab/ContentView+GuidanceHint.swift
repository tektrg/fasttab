import SwiftUI

extension ContentView {
    var guidanceHint: GuidanceHint {
        let store = shortcutStore
        let selectedIndex = appState.selectedIndex
        let isResultFocused = selectedIndex >= 0 && !isSearchFocused
        let hasResults = !displayedItems.isEmpty
        let queryEmpty = searchText.isEmpty
        let isShowAllTabsFocused = selectedIndex >= 0
            && displayedItems.indices.contains(selectedIndex)
            && displayedItems[selectedIndex].result == nil

        // 0: Shortcut modifier still held on fresh open — search bar focused, no cycling yet
        if isShortcutModifierHeld && !hasCycled && isSearchFocused {
            return GuidanceHint(tokens: [
                .init(glyph: store.keyDisplayName, label: "next"),
                .init(glyph: "Esc", label: "cancel")
            ])
        }

        // 1–2: Pointer swipe past confirm threshold — "release to act"
        if pointerSwipeResultID != nil, !didConfirmPointerSwipe,
           abs(pointerSwipeOffset) >= ResultSwipeMetrics.confirmDistance {
            return pointerSwipeOffset < 0
                ? GuidanceHint(tokens: [.init(glyph: "←", label: "release to delete")])
                : GuidanceHint(tokens: [.init(glyph: "→", label: "release to copy link")])
        }

        // 3–4: Pointer swipe resting at reveal distance (gesture ended, not confirmed)
        if pointerSwipeResultID != nil, pointerSwipeAction != nil,
           !isPointerSwipeGestureActive, !didConfirmPointerSwipe {
            return pointerSwipeOffset < 0
                ? GuidanceHint(tokens: [.init(glyph: "←", label: "swipe more to delete"),
                                        .init(glyph: "Esc", label: "cancel")])
                : GuidanceHint(tokens: [.init(glyph: "→", label: "swipe more to copy"),
                                        .init(glyph: "Esc", label: "cancel")])
        }

        // 5–6: Pointer swipe in progress, below confirm threshold
        if pointerSwipeResultID != nil, isPointerSwipeGestureActive,
           abs(pointerSwipeOffset) > 3 {
            return pointerSwipeOffset < 0
                ? GuidanceHint(tokens: [.init(glyph: "←", label: "keep swiping to delete")])
                : GuidanceHint(tokens: [.init(glyph: "→", label: "keep swiping to copy link")])
        }

        // 7: Modifier cycling mode — user is holding modifier and cycling with shortcut key
        if hasCycled {
            return GuidanceHint(tokens: [
                .init(glyph: store.modifierSymbols, label: isShowAllTabsFocused ? "release to show" : "release to open"),
                .init(glyph: store.keyDisplayName, label: "next"),
                .init(glyph: "Esc", label: "cancel")
            ])
        }

        // 8: Keyboard swipe revealed, awaiting second press to confirm
        if keyboardSwipeResultID != nil {
            let arrow = keyboardSwipeAction == .delete ? "←" : "→"
            let verb = keyboardSwipeAction == .delete ? "delete" : "copy"
            return GuidanceHint(tokens: [
                .init(glyph: arrow, label: "press again to \(verb)"),
                .init(glyph: "Esc", label: "cancel")
            ])
        }

        // 9–10: Result focused via keyboard navigation (arrow keys or space)
        if isResultFocused && (lastInteractionKey == .upDown || lastInteractionKey == .space) {
            if isShowAllTabsFocused {
                return GuidanceHint(tokens: [
                    .init(glyph: "↵", label: "show all"),
                    .init(glyph: "Esc", label: "back")
                ])
            }

            if !hasDiscoveredSwipe {
                return GuidanceHint(tokens: [
                    .init(glyph: "←→", label: "more options"),
                    .init(glyph: "↵", label: "open"),
                    .init(glyph: "Esc", label: "back to search")
                ])
            } else {
                return GuidanceHint(tokens: [
                    .init(glyph: "←", label: "delete"),
                    .init(glyph: "→", label: "copy"),
                    .init(glyph: "↵", label: "open"),
                    .init(glyph: "Esc", label: "back")
                ])
            }
        }

        // 11: Result focused via mouse click (no keyboard nav recorded)
        if isResultFocused && lastInteractionKey == .none {
            if isShowAllTabsFocused {
                return GuidanceHint(tokens: [
                    .init(glyph: "↑↓", label: "navigate"),
                    .init(glyph: "↵", label: "show all")
                ])
            }

            return GuidanceHint(tokens: [
                .init(glyph: "↑↓", label: "navigate"),
                .init(glyph: "←", label: "delete"),
                .init(glyph: "→", label: "copy"),
                .init(glyph: "↵", label: "open")
            ])
        }

        // 12: Mouse hover over a row, no keyboard result selected
        if hoveredResultID != nil && !isResultFocused {
            return GuidanceHint(tokens: [
                .init(glyph: "←", label: "swipe to delete"),
                .init(glyph: "→", label: "swipe to copy")
            ])
        }

        // 13: Search field focused, empty query, results present
        if !isResultFocused && queryEmpty && hasResults {
            return GuidanceHint(tokens: [
                .init(glyph: "↑↓", label: "navigate"),
                .init(glyph: "↵", label: "open"),
                .init(glyph: "@", label: "scope"),
                .init(glyph: "Esc", label: "dismiss")
            ])
        }

        // 14: Search field focused, active query, results present
        if !isResultFocused && !queryEmpty && hasResults {
            return GuidanceHint(tokens: [
                .init(glyph: "↑↓", label: "navigate"),
                .init(glyph: "↵", label: "open"),
                .init(glyph: "@", label: "scope")
            ])
        }

        // 15–16: No results — empty-state UI owns this moment
        if !hasResults { return .empty }

        // 18: Fallback
        return GuidanceHint(tokens: [
            .init(glyph: "↑↓", label: "navigate"),
            .init(glyph: "↵", label: "open"),
            .init(glyph: "Esc", label: "dismiss")
        ])
    }
}
