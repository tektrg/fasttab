import Foundation

/// The keyboard-driven state of one open permission box on the permission card: which
/// choice is highlighted and whether "Allow always" is waiting for its second press. Pure:
/// a key goes in, an `Effect` for the model to carry out comes out.
///
/// Safety rules, all decided here: nothing is sent until the box has been re-read from the
/// pane (`phase == .ready`); nothing is highlighted to begin with, and Enter with no
/// highlight does nothing (so no choice, destructive or not, is ever the default); a digit only
/// highlights; "Allow always" needs a second press, and any other key cancels it.
struct PermissionCardState: Equatable, Sendable {
    enum Key: Equatable, Sendable {
        /// 1...9: the number the box shows on an option (highlights it, never sends).
        case digit(Int)
        case up
        case down
        case enter
        case escape
        /// The card's action button.
        case send
        /// Any other key: it cancels a pending "Allow always" and does nothing else.
        case other
    }

    enum Effect: Equatable, Sendable {
        case none
        case send(PermissionChoice)
        /// Back to the list.
        case close
    }

    enum Phase: Equatable, Sendable {
        /// The box is being read from the pane; nothing can be decided yet.
        case checking
        case ready
        /// The box cannot be decided from here (gone, or not readable): the reason, in words.
        case unavailable(String)
    }

    /// What the footer hints should say.
    enum HintMode: Equatable, Sendable {
        case checking
        case unavailable
        case choosing
        case chosen
        case confirmingAlways
    }

    /// The box the decision would be sent for. First the status feed's copy (shown while the
    /// pane is read), then the pane's own reading, which is what the dashboard compares against.
    private(set) var prompt: PermissionPrompt
    private(set) var phase: Phase = .checking
    private(set) var highlighted: PermissionChoice?
    private(set) var isConfirmingAlways = false
    /// Set when the pane's box was not the one the status feed showed.
    private(set) var changedNote: String?

    init(prompt: PermissionPrompt) {
        self.prompt = prompt
    }

    static let changedNoteText = "The terminal shows a different prompt than the list did. This is what it shows now."

    var hintMode: HintMode {
        switch phase {
        case .checking: .checking
        case .unavailable: .unavailable
        case .ready: isConfirmingAlways ? .confirmingAlways : (highlighted == nil ? .choosing : .chosen)
        }
    }

    var choices: [PermissionChoice] { phase == .ready ? prompt.choices : [] }

    /// The action button's words: the highlighted choice, or "Confirm always allow" on its second press.
    var actionTitle: String {
        guard let highlighted else { return "Choose an option" }
        return isConfirmingAlways ? "Confirm always allow" : highlighted.title
    }

    var canSend: Bool { phase == .ready && highlighted != nil }

    /// The label the box gives the highlighted choice (for "Allow always" it says what is being allowed for good).
    var highlightedOptionLabel: String? {
        highlighted.flatMap { prompt.option(for: $0)?.label }
    }

    // MARK: - Reading the pane

    /// The pane has been read: `live` is the box it shows now, nil when it shows none.
    mutating func resolve(live: PermissionPrompt?, failure: String?) {
        guard phase == .checking else { return }
        if let live {
            if live.identity != prompt.identity { changedNote = Self.changedNoteText }
            prompt = live
            phase = .ready
        } else {
            phase = .unavailable(failure ?? "The prompt is no longer open in the terminal.")
        }
    }

    // MARK: - Keys

    mutating func handle(_ key: Key) -> Effect {
        if key == .escape {
            if isConfirmingAlways {
                isConfirmingAlways = false
                return .none
            }
            return .close
        }
        guard phase == .ready else { return .none }
        switch key {
        case .up: move(by: -1)
        case .down: move(by: 1)
        case .digit(let number): highlight(numbered: number)
        case .enter, .send: return sendHighlighted()
        case .other: isConfirmingAlways = false
        case .escape: break
        }
        return .none
    }

    /// A click on a choice: highlights it (never sends: that is the action button).
    mutating func clickChoice(_ choice: PermissionChoice) {
        guard phase == .ready, choices.contains(choice) else { return }
        isConfirmingAlways = false
        highlighted = choice
    }

    private mutating func move(by step: Int) {
        isConfirmingAlways = false
        let all = choices
        guard !all.isEmpty else { return }
        guard let current = highlighted, let position = all.firstIndex(of: current) else {
            highlighted = step > 0 ? all.first : all.last
            return
        }
        highlighted = all[min(max(0, position + step), all.count - 1)]
    }

    private mutating func highlight(numbered number: Int) {
        isConfirmingAlways = false
        guard let choice = choices.first(where: { prompt.option(for: $0)?.index == number }) else { return }
        highlighted = choice
    }

    private mutating func sendHighlighted() -> Effect {
        guard let choice = highlighted else { return .none }
        if choice == .allowAlways, !isConfirmingAlways {
            isConfirmingAlways = true
            return .none
        }
        return .send(choice)
    }
}
