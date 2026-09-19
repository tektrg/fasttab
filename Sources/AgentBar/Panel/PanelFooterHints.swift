import Foundation

/// The key hints in the footer (the answer and permission cards have their own). ←/→ (buttons) and space (peek) work only while
/// the search field is empty; with text in it they belong to the text field
/// (caret, literal space), so the hints for them disappear too.
enum PanelFooterHints {
    struct Context: Equatable {
        var isPeeking = false
        /// A row button is highlighted (←/→ / ↩ act on it).
        var hasHighlightedButton = false
        var searchIsEmpty = true
        /// The answer card is open; what its keys do depends on this.
        var answerMode: AnswerCardState.HintMode?
        /// The permission card is open; what its keys do depends on this.
        var permissionMode: PermissionCardState.HintMode?
    }

    static func text(for context: Context) -> String {
        if let answerMode = context.answerMode { return answerText(for: answerMode) }
        if let permissionMode = context.permissionMode { return permissionText(for: permissionMode) }
        if context.isPeeking { return "space/esc back   ↩ switch" }
        if context.hasHighlightedButton { return "←→ button   ↩ press   esc back" }
        if context.searchIsEmpty { return "↑↓ select   ←→ actions   space peek   ↩ switch   esc close" }
        return "↑↓ select   ↩ switch   esc close"
    }

    private static func permissionText(for mode: PermissionCardState.HintMode) -> String {
        switch mode {
        case .checking: "reading the terminal…   esc back"
        case .unavailable: "esc back"
        case .choosing: "↑↓ or number to choose   esc back"
        case .chosen: "↑↓ change   ↩ press   esc back"
        case .confirmingAlways: "↩ confirm always allow   any other key cancels"
        }
    }

    private static func answerText(for mode: AnswerCardState.HintMode) -> String {
        switch mode {
        case .singleSelect: "1-9 pick   ↑↓ move   ↩ send   esc back"
        case .multiSelect: "1-9/space tick   ↑↓ move   ↩ submit   esc back"
        case .typing: "↩ send   ⇧↩ new line   ↑↓/esc back to options"
        }
    }
}
