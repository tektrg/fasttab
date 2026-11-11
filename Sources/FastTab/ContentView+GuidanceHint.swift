import SwiftUI
import IndieCommandBar

extension ContentView {
    /// Fast Tab's hint words; the hint rules live in IndieCommandBar
    /// (`CommandBarGuidance`).
    static let guidanceWords = CommandBarGuidanceWords(
        trailingVerb: "delete",
        leadingVerb: "copy",
        leadingVerbLong: "copy link",
        extraRowVerb: "show all",
        scopeGlyph: "@"
    )

    var guidanceHint: GuidanceHint {
        let store = shortcutStore
        let selectedIndex = appState.selectedIndex
        var state = CommandBarGuidanceState()
        state.cycleKeyGlyph = store.keyDisplayName
        state.cycleModifierGlyph = store.modifierSymbols
        state.isModifierHeld = cycleSession.isModifierHeld
        state.hasCycled = cycleSession.hasCycled
        state.isSearchFocused = isSearchFocused
        state.isRowSwipeEnabled = env.isRowSwipeEnabled()
        state.pointerSwipePhase = pointerSwipe.phase
        state.keyboardSwipeEdge = keyboardSwipe.rowID != nil ? (keyboardSwipe.edge ?? .leading) : nil
        state.selectedIndex = selectedIndex
        state.hasResults = !displayedItems.isEmpty
        state.queryIsEmpty = searchText.isEmpty
        state.isExtraRowFocused = displayedItems.indices.contains(selectedIndex)
            && displayedItems[selectedIndex].isShowAllTabs
        state.lastInteraction = lastInteractionKey
        state.hasDiscoveredSwipe = hasDiscoveredSwipe
        state.isHoveringRow = hoveredResultID != nil
        return CommandBarGuidance.hint(for: state, words: Self.guidanceWords)
    }
}
