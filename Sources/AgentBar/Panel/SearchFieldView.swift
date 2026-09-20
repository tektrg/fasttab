import SwiftUI

/// Search box at the top of the panel; grabs keyboard focus on every show.
/// ←/→ walk the selected row's buttons, but only while the box is empty (with
/// text in it they move the caret); Enter presses the highlighted button, else
/// switches to the agent. With a card (answer or permission) open the keys drive the card.
struct SearchFieldView: View {
    @ObservedObject var model: AgentPanelModel
    let onClose: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            field
        }
        .padding(.horizontal, 18)
        .frame(height: AgentPanelMetrics.searchFieldHeight)
    }

    /// While a card is open the search box types nothing: digits pick an
    /// option, other characters are dropped. Arrows, space, return and escape have
    /// their own handlers, and shortcuts (⌘,) pass through.
    private func answerCardKeyPress(_ press: KeyPress) -> KeyPress.Result {
        // ⌘C copies the agent's details. This handler only runs while the search box has the
        // keyboard, so a text field or a selection elsewhere in the card keeps its own copy.
        if model.isCardOpen, press.modifiers == .command, press.characters == "c" {
            return model.copyOpenCardIdentity() ? .handled : .ignored
        }
        guard model.isCardOpen, press.modifiers.subtracting(.shift).isEmpty else { return .ignored }
        switch press.key {
        case .upArrow, .downArrow, .leftArrow, .rightArrow, .space, .return, .escape, .tab:
            return .ignored
        default:
            if let number = Int(press.characters), (1...9).contains(number) { model.handleCardDigit(number) }
            else { model.handleCardStrayKey() }
            return .handled
        }
    }

    private var field: some View {
        TextField("Search agents", text: $model.query)
            .textFieldStyle(.plain)
            .font(.system(size: 18))
            .focused($isFocused)
            .onSubmit { model.activateSelected(isKeyRepeat: NSApp.currentEvent?.isARepeat ?? false) }
            .onKeyPress(.upArrow) { model.moveSelectionOrAnswerHighlight(by: -1); return .handled }
            .onKeyPress(.downArrow) { model.moveSelectionOrAnswerHighlight(by: 1); return .handled }
            .onKeyPress(.leftArrow) { model.moveButtonHighlight(by: -1) ? .handled : .ignored }
            .onKeyPress(.rightArrow) { model.moveButtonHighlight(by: 1) ? .handled : .ignored }
            .onKeyPress(keys: [.space], phases: .down) { press in
                guard press.modifiers.isEmpty else { return .ignored }
                return model.togglePeek() ? .handled : .ignored
            }
            .onKeyPress(phases: .down) { press in answerCardKeyPress(press) }
            .onExitCommand {
                if model.dismissFooterNotice() { return }   // a failure notice goes first, then esc does its usual job
                if model.backOutOfButtons() { return }
                if model.peek != nil { model.closePeek() } else { onClose() }
            }
            .onAppear { isFocused = true }
            .onChange(of: model.focusRequest) {
                // The answer card's text view may have taken the keyboard without SwiftUI knowing,
                // so "focused" can already read true: flip it to make the field take it back.
                isFocused = false
                DispatchQueue.main.async { isFocused = true }
            }
    }
}
