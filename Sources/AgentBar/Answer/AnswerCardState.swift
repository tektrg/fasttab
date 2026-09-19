import Foundation

/// The keyboard-driven state of one open question in the answer card: which
/// option is highlighted, what is ticked or typed, and whether an answer is
/// on its way. Pure: a key goes in, an `Effect` for the model to carry out
/// comes out, and nothing is ever sent without the user pressing a key that
/// means "send".
struct AnswerCardState: Equatable, Sendable {
    enum Key: Equatable, Sendable {
        /// 1...9: the option the picker numbers so.
        case digit(Int)
        case up
        case down
        case space
        case enter
        case escape
        /// The Send / Submit button: sends what is ready, never opens the text field.
        case send
        /// ↑ / ↓ pressed in the text field with the caret already on its first / last line:
        /// back to the options, one option up / down, text kept.
        case leaveTypingUp
        case leaveTypingDown
    }

    enum Effect: Equatable, Sendable {
        case none
        case send(AnswerChoice)
        /// Back to the list.
        case close
    }

    enum Phase: Equatable, Sendable {
        case choosing
        /// The free-text row has the keyboard.
        case typingOther
    }

    /// What the footer hints should say.
    enum HintMode: Equatable, Sendable {
        case singleSelect
        case multiSelect
        case typing
    }

    static let pickAtLeastOneMessage = "Tick at least one option first (space ticks the highlighted one)."

    private(set) var question: AnswerableQuestion
    private(set) var highlightedPosition = 0
    private(set) var checkedIndices: Set<Int> = []
    private(set) var phase: Phase = .choosing
    /// Bound to the free-text field.
    var otherText = ""
    /// The last refusal (the dashboard's words) or a local hint; cleared by the next key.
    private(set) var errorText: String?

    init(question: AnswerableQuestion, errorText: String? = nil) {
        self.question = question
        self.errorText = errorText
    }

    var hintMode: HintMode {
        switch phase {
        case .typingOther: .typing
        case .choosing: question.isMultiSelect ? .multiSelect : .singleSelect
        }
    }

    var highlightedOption: AnswerableQuestion.Option {
        question.options[highlightedPosition]
    }

    func isChecked(_ option: AnswerableQuestion.Option) -> Bool {
        checkedIndices.contains(option.index)
    }

    /// What the Send / Submit button (and Enter) would send right now; nil when nothing is ready.
    var readyChoice: AnswerChoice? {
        switch phase {
        case .typingOther: OtherAnswerText.sendable(otherText).map(AnswerChoice.text)
        case .choosing:
            if question.isMultiSelect { checkedIndices.isEmpty ? nil : .select(checkedIndices.sorted()) }
            else { highlightedOption.isOther ? nil : .select([highlightedOption.index]) }
        }
    }

    /// Set while what is typed will reach the agent changed (line breaks become spaces, length capped).
    var otherTextNote: String? {
        phase == .typingOther ? OtherAnswerText.note(for: otherText) : nil
    }

    // MARK: - Keys

    mutating func handle(_ key: Key) -> Effect {
        switch phase {
        case .typingOther: return handleWhileTyping(key)
        case .choosing:
            errorText = nil
            return handleWhileChoosing(key)
        }
    }

    private mutating func handleWhileChoosing(_ key: Key) -> Effect {
        switch key {
        case .escape:
            return .close
        case .up:
            highlightedPosition = max(0, highlightedPosition - 1)
        case .down:
            highlightedPosition = min(question.options.count - 1, highlightedPosition + 1)
        case .digit(let number):
            guard let position = question.options.firstIndex(where: { $0.index == number }) else { return .none }
            highlightedPosition = position
            return choose(at: position, sendsSingleSelectAtOnce: true)
        case .space:
            guard question.isMultiSelect else { return .none }
            return choose(at: highlightedPosition, sendsSingleSelectAtOnce: false)
        case .enter:
            return confirmHighlightedOrChecked()
        case .send:
            return sendReadyChoice()
        case .leaveTypingUp, .leaveTypingDown:
            break
        }
        return .none
    }

    private mutating func handleWhileTyping(_ key: Key) -> Effect {
        switch key {
        case .escape:
            phase = .choosing
            errorText = nil
        case .enter:
            guard let choice = readyChoice else { return .none }
            return startSending(choice)
        case .send:
            guard let choice = readyChoice else { return .none }
            return startSending(choice)
        case .leaveTypingUp:
            leaveTyping(movingBy: -1)
        case .leaveTypingDown:
            leaveTyping(movingBy: 1)
        case .digit, .up, .down, .space:
            break   // the text field has these
        }
        return .none
    }

    /// Back to the options with the typed text kept (it comes back when Other is entered again).
    private mutating func leaveTyping(movingBy step: Int) {
        phase = .choosing
        errorText = nil
        highlightedPosition = min(max(0, highlightedPosition + step), question.options.count - 1)
    }

    /// A digit, a click or Space landed on the option at `position`.
    private mutating func choose(at position: Int, sendsSingleSelectAtOnce: Bool) -> Effect {
        let option = question.options[position]
        highlightedPosition = position
        if option.isOther {
            phase = .typingOther
            return .none
        }
        if question.isMultiSelect {
            if !checkedIndices.insert(option.index).inserted { checkedIndices.remove(option.index) }
            return .none
        }
        return sendsSingleSelectAtOnce ? startSending(.select([option.index])) : .none
    }

    /// Enter: on the Other row it opens the text field (text kept from before);
    /// elsewhere it sends the highlighted option, or the ticked ones in a multi-select.
    private mutating func confirmHighlightedOrChecked() -> Effect {
        if highlightedOption.isOther {
            phase = .typingOther
            return .none
        }
        return sendReadyChoice()
    }

    private mutating func sendReadyChoice() -> Effect {
        if let choice = readyChoice { return startSending(choice) }
        if question.isMultiSelect { errorText = Self.pickAtLeastOneMessage }
        return .none
    }

    private mutating func startSending(_ choice: AnswerChoice) -> Effect {
        errorText = nil
        return .send(choice)
    }

    // MARK: - Mouse

    /// A click on the option at `position`: ticks it (multi), opens the text
    /// row (Other) or highlights it (single). Also works from the text field
    /// (the typed text is kept). Never sends: that is the Send button.
    mutating func clickOption(at position: Int) {
        guard question.options.indices.contains(position) else { return }
        errorText = nil
        phase = .choosing
        _ = choose(at: position, sendsSingleSelectAtOnce: false)
    }

    /// The Send / Submit button.
    mutating func pressSend() -> Effect {
        handle(.send)
    }

    // MARK: - Drafts

    /// What the user had put in, kept when a send fails so a retry starts where they left off.
    var draft: AnswerDraft {
        AnswerDraft(identity: question.identity, otherText: otherText, checkedIndices: checkedIndices, highlightedPosition: highlightedPosition)
    }

    /// Takes a draft back, when it is for this very question.
    mutating func restore(_ draft: AnswerDraft) {
        guard draft.identity == question.identity, question.options.indices.contains(draft.highlightedPosition) else { return }
        otherText = draft.otherText
        checkedIndices = draft.checkedIndices.intersection(question.options.map(\.index))
        highlightedPosition = draft.highlightedPosition
    }

    // MARK: - Following the dashboard

    /// The pane's question is another one now: start over on it, keeping the
    /// message that explains what happened.
    func replacing(question newQuestion: AnswerableQuestion) -> AnswerCardState {
        AnswerCardState(question: newQuestion, errorText: errorText)
    }
}
