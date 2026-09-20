import Foundation

/// The keyboard-driven state of one open plan-approval box on the plan card: which row is
/// highlighted, whether a privilege-changing row waits for its second press, and whether the
/// feedback text box is open. Pure: a key goes in, an `Effect` for the model to carry out comes out.
///
/// Safety rules, all decided here: nothing is sent until the box has been re-read from the pane
/// (`phase == .ready`); nothing is highlighted to begin with (the terminal's own cursor row is not
/// a default) and Return with no highlight does nothing; a digit or arrow only highlights; a row
/// that changes what the agent may do (`PermissionPrompt.isPrivilegeChange`) needs a second press
/// that names the change; feedback is never sent empty. Rows are the box's own, verbatim.
struct PlanCardState: Equatable, Sendable {
    typealias Key = PermissionCardState.Key
    typealias Phase = PermissionCardState.Phase

    /// What is sent: the row's number (the dashboard corroborates it and the label against the box it
    /// reads) and, for the feedback row only, the text.
    struct Selection: Equatable, Sendable {
        let option: PermissionPrompt.Option
        let feedback: String?
    }

    enum Effect: Equatable, Sendable {
        case none
        case send(Selection)
        /// Back to the list.
        case close
    }

    /// The dashboard types at most this many characters of feedback (`_clean_free_text`).
    static let feedbackMaxCharacters = OtherAnswerText.maximumLength

    private(set) var prompt: PermissionPrompt
    private(set) var phase: Phase = .checking
    private(set) var highlightedIndex: Int?
    private(set) var isConfirmingPrivilege = false
    private(set) var isTypingFeedback = false
    /// The feedback as typed (the text box edits it directly).
    var feedbackText = ""
    /// Set when the pane's box was not the one the status feed showed.
    private(set) var changedNote: String?

    init(prompt: PermissionPrompt) {
        self.prompt = prompt
    }

    // MARK: - What the card shows

    var options: [PermissionPrompt.Option] { phase == .ready ? prompt.options : [] }

    var highlightedOption: PermissionPrompt.Option? {
        highlightedIndex.flatMap { index in options.first { $0.index == index } }
    }

    var hintMode: PermissionCardState.HintMode {
        switch phase {
        case .checking: .checking
        case .unavailable: .unavailable
        case .ready:
            if isTypingFeedback { .typingFeedback } else if isConfirmingPrivilege { .confirmingPrivilege } else if highlightedIndex == nil { .choosing } else { .chosen }
        }
    }

    /// The second-press sentence, while a privilege row waits for it.
    var confirmText: String? {
        guard isConfirmingPrivilege, let option = highlightedOption else { return nil }
        return PermissionPrompt.privilegeConfirmText(for: option)
    }

    /// The action button's words: the row's own label (never a made-up verb), "Confirm: …" on a second press.
    var actionTitle: String {
        guard let option = highlightedOption else { return "Choose an option" }
        if isTypingFeedback { return "Send feedback" }
        return isConfirmingPrivilege ? "Confirm: \(option.label)" : option.label
    }

    var canSend: Bool {
        guard phase == .ready, highlightedOption != nil else { return false }
        return !isTypingFeedback || feedbackToSend != nil
    }

    /// What would be typed: line breaks and runs of spaces become one space, capped like the dashboard does; nil when blank.
    /// The same rules as a free-text answer (`OtherAnswerText`), which caps in the characters the dashboard counts.
    var feedbackToSend: String? { OtherAnswerText.sendable(feedbackText) }

    var isFeedbackTooLong: Bool {
        TerminalSafeText.withoutControlCharacters(feedbackText).split(whereSeparator: \.isWhitespace).joined(separator: " ").unicodeScalars.count > Self.feedbackMaxCharacters
    }

    // MARK: - Reading the pane

    /// The pane has been read: `live` is the box it shows now, nil when it shows none.
    mutating func resolve(live: PermissionPrompt?, failure: String?) {
        guard phase == .checking else { return }
        if let live {
            if live.identity != prompt.identity { changedNote = PermissionCardState.changedNoteText }
            prompt = live
            phase = .ready
        } else {
            phase = .unavailable(failure ?? "The prompt is no longer open in the terminal.")
        }
    }

    // MARK: - Keys

    mutating func handle(_ key: Key) -> Effect {
        if key == .escape { return escape() }
        guard phase == .ready else { return .none }
        if isTypingFeedback {
            // The text box owns the keyboard: only Return (send) and Escape (leave) reach here.
            return key == .enter || key == .send ? sendHighlighted() : .none
        }
        switch key {
        case .up: move(by: -1)
        case .down: move(by: 1)
        case .digit(let number): highlight(number)
        case .enter, .send: return sendHighlighted()
        case .other: isConfirmingPrivilege = false
        case .escape: break
        }
        return .none
    }

    /// A click on a row: highlights it (never sends: that is the action button). The feedback row opens its text box.
    mutating func clickOption(index: Int) {
        guard phase == .ready, options.contains(where: { $0.index == index }) else { return }
        isConfirmingPrivilege = false
        highlightedIndex = index
        isTypingFeedback = highlightedOption.map(prompt.isFeedbackOption) ?? false
    }

    private mutating func escape() -> Effect {
        if isTypingFeedback {
            isTypingFeedback = false
            return .none
        }
        if isConfirmingPrivilege {
            isConfirmingPrivilege = false
            return .none
        }
        return .close
    }

    private mutating func move(by step: Int) {
        isConfirmingPrivilege = false
        let all = options
        guard !all.isEmpty else { return }
        guard let current = highlightedIndex, let position = all.firstIndex(where: { $0.index == current }) else {
            highlightedIndex = (step > 0 ? all.first : all.last)?.index
            return
        }
        highlightedIndex = all[min(max(0, position + step), all.count - 1)].index
    }

    private mutating func highlight(_ number: Int) {
        isConfirmingPrivilege = false
        guard options.contains(where: { $0.index == number }) else { return }
        highlightedIndex = number
    }

    private mutating func sendHighlighted() -> Effect {
        guard let option = highlightedOption else { return .none }
        if prompt.isFeedbackOption(option) {
            guard isTypingFeedback else {
                isTypingFeedback = true   // Return on the feedback row opens the box; nothing goes yet
                return .none
            }
            guard let feedback = feedbackToSend else { return .none }
            return .send(Selection(option: option, feedback: feedback))
        }
        if PermissionPrompt.isPrivilegeChange(option), !isConfirmingPrivilege {
            isConfirmingPrivilege = true
            return .none
        }
        return .send(Selection(option: option, feedback: nil))
    }
}
