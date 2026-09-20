import Foundation

/// The key hints in the footer (the answer and permission cards have their own; while a failure
/// notice is showing the only hint is that esc dismisses it, since esc then no longer closes
/// the panel or backs out until the notice is gone). ←/→ (buttons) and space (peek) work only while
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
        /// The message card is open; what its keys do depends on this.
        var messageMode: MessageCard.HintMode?
        /// A failure notice is showing: esc closes it before it does anything else.
        var hasDismissibleNotice = false
    }

    static func text(for context: Context) -> String {
        if context.hasDismissibleNotice { return "esc dismiss notice" }
        if let answerMode = context.answerMode { return answerText(for: answerMode) }
        if let permissionMode = context.permissionMode { return permissionText(for: permissionMode) }
        if let messageMode = context.messageMode { return messageText(for: messageMode) }
        if context.isPeeking { return "space/esc back   ↩ switch" }
        if context.hasHighlightedButton { return "←→ button   ↩ press   esc back" }
        if context.searchIsEmpty { return "↑↓ select   ←→ actions   space peek   ↩ switch   esc close" }
        return "↑↓ select   ↩ switch   esc close"
    }

    private static func messageText(for mode: MessageCard.HintMode) -> String {
        switch mode {
        case .composing: "↩ send   esc back"
        case .confirming: "↩ send anyway   edit to cancel   esc back"
        case .sending: "sending…"
        }
    }

    private static func permissionText(for mode: PermissionCardState.HintMode) -> String {
        switch mode {
        case .checking: "reading the terminal…   ⌘C copy info   esc back"
        case .unavailable: "⌘C copy info   esc back"
        case .choosing: "↑↓ or number to choose   ⌘C copy info   esc back"
        case .chosen: "↑↓ change   ↩ press   ⌘C copy info   esc back"
        case .confirmingAlways: "↩ confirm always allow   any other key cancels"
        case .confirmingPrivilege: "↩ confirm   any other key cancels"
        case .typingFeedback: "↩ send feedback   ⇧↩ new line   esc back to options"
        }
    }

    private static func answerText(for mode: AnswerCardState.HintMode) -> String {
        switch mode {
        case .singleSelect: "1-9 pick   ↑↓ move   ↩ send   ⌘C copy info   esc back"
        case .multiSelect: "1-9/space tick   ↑↓ move   ↩ submit   ⌘C copy info   esc back"
        case .typing: "↩ send   ⇧↩ new line   ↑↓/esc back to options"
        case .form: "click to answer   ↩ submit when all answered   ⌘C copy info   esc back"
        case .formBusy: "⌘C copy info   esc back when finished"
        }
    }
}
