import Foundation

/// The key hints in the footer. ←/→ (buttons) and space (peek) work only while
/// the search field is empty; with text in it they belong to the text field
/// (caret, literal space), so the hints for them disappear too.
enum PanelFooterHints {
    struct Context: Equatable {
        var isPeeking = false
        /// A row button is highlighted (←/→ / ↩ act on it).
        var hasHighlightedButton = false
        var searchIsEmpty = true
    }

    static func text(for context: Context) -> String {
        if context.isPeeking { return "space/esc back   ↩ switch" }
        if context.hasHighlightedButton { return "←→ button   ↩ press   esc back" }
        if context.searchIsEmpty { return "↑↓ select   ←→ actions   space peek   ↩ switch   esc close" }
        return "↑↓ select   ↩ switch   esc close"
    }
}
