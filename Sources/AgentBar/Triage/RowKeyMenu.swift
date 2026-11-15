import Foundation

/// ⌘K in the agent list: the selected row's ⋯ menu as a keyboard menu (gotcha 17: a native `Menu`
/// cannot be opened from code, so this is the keyboard path to the SAME items, `AgentActionList.menuItems`).
/// When the agent waits on a question, its answers come FIRST (`answerEntries`), then the actions;
/// numbering runs on through both. 1…9 quick-select (10+ arrows only), ↑/↓ move (a disabled item just
/// won't fire), ↩ activates, Esc / ⌘K close only the menu. Pure.
struct RowKeyMenu: Equatable {
    enum Entry: Equatable {
        /// One option of a single-select question: picking it answers (the Other row opens the card typing).
        case option(AnswerableQuestion.Option)
        /// "Answer…": opens the card the row's red button opens (`.answer` or `.review`).
        case openCard(RowButton)
        /// The question is still being read: disabled.
        case reading
        case action(RowButtonSpec)

        static let readingTitle = "Reading question…"
        static let openCardTitle = "Answer…"
        static let otherTitle = "Type an answer…"

        var label: String {
            switch self {
            case .option(let option): option.isOther ? Self.otherTitle : option.label
            case .openCard: Self.openCardTitle
            case .reading: Self.readingTitle
            case .action(let spec): spec.label
            }
        }

        var isEnabled: Bool {
            switch self {
            case .reading: false
            case .action(let spec): spec.isEnabled
            case .option, .openCard: true
            }
        }

        /// Tooltip: the full label (+ description) of an option, else why disabled / the hint.
        var help: String {
            switch self {
            case .option(let option): option.description.isEmpty ? option.label : "\(option.label) — \(option.description)"
            case .openCard(let button): button == .review ? "Open the review card" : "Open the answer card"
            case .reading: RowButtons.readingOptionsReason
            case .action(let spec): spec.disabledReason ?? spec.hint ?? ""
            }
        }

        var isAnswer: Bool { if case .action = self { false } else { true } }
    }

    let agentID: String
    let entries: [Entry]
    /// The question the options belong to (nil: no options). A pick is sent only while the card opens on it.
    let questionIdentity: QuestionIdentity?
    private(set) var highlighted: Int

    enum Key: Equatable { case up, down, enter, escape, toggle, digit(Int), other }
    enum Effect: Equatable {
        /// Key used, menu stays.
        case none
        case close
        /// Close the menu and press this button on the row (`AgentPanelModel.press`).
        case activate(RowButton)
        /// Close the menu and answer with this option number (`AgentPanelModel.answerFromKeyMenu`).
        case answer(optionIndex: Int)
    }

    /// Nil when there is nothing to show. `items` = the row's ⋯ list; its Answer / Review (if any) are
    /// dropped — the answer section stands for them.
    init?(agentID: String, answers: [Entry] = [], questionIdentity: QuestionIdentity? = nil, items: [RowButtonSpec]) {
        let actions = items.filter { $0.button != .answer && $0.button != .review }.map(Entry.action)
        guard !(answers.isEmpty && actions.isEmpty) else { return nil }
        self.agentID = agentID
        self.entries = answers + actions
        self.questionIdentity = questionIdentity
        highlighted = entries.firstIndex(where: \.isEnabled) ?? 0
    }

    /// The ⋯ actions (without the answer section).
    var items: [RowButtonSpec] { entries.compactMap { if case .action(let spec) = $0 { spec } else { nil } } }
    var answerCount: Int { entries.filter(\.isAnswer).count }

    /// The answer section for `agent`. Single-select picker → its options; multi-select, a multi-question
    /// hook form or a permission/plan box → one "Answer…" that opens the card (ticking and forms belong
    /// in the card); still reading → "Reading question…"; an answer being sent → nothing.
    static func answerEntries(for agent: AgentSnapshot, isAwaiting: Bool) -> [Entry] {
        guard !isAwaiting else { return [] }
        switch agent.blockedOnYou {
        case .question(let question)?:
            let isHookForm = (agent.hookRequest?.questions.count ?? 0) >= PendingQuestionForm.minimumQuestionCount
            if question.isMultiSelect || isHookForm { return [.openCard(.answer)] }
            return question.options.map(Entry.option)
        case .questionLoading?: return [.reading]
        case .permissionReview?: return [.openCard(.review)]
        case .questionNotAnswerable?, .permission?, nil: return []
        }
    }

    /// "1".."9" for the first nine entries, nil after.
    static func number(at index: Int) -> String? { index < 9 ? String(index + 1) : nil }

    mutating func handle(_ key: Key) -> Effect {
        switch key {
        case .up: highlighted = max(0, highlighted - 1); return .none
        case .down: highlighted = min(entries.count - 1, highlighted + 1); return .none
        case .escape, .toggle: return .close
        case .enter: return activate(highlighted)
        case .digit(let number):
            guard (1...min(9, entries.count)).contains(number) else { return .none }
            highlighted = number - 1
            return activate(highlighted)
        case .other: return .none
        }
    }

    func activate(_ index: Int) -> Effect {
        guard entries.indices.contains(index) else { return .none }
        switch entries[index] {
        case .option(let option): return .answer(optionIndex: option.index)
        case .openCard(let button): return .activate(button)
        case .reading: return .none
        case .action(let spec): return spec.isEnabled ? .activate(spec.button) : .none
        }
    }

    /// The key as the panel's key monitor sees it (macOS key codes). ⌘K toggles; other ⌘ keys are `.other`.
    static func key(keyCode: UInt16, characters: String, command: Bool) -> Key {
        if command { return characters.lowercased() == "k" ? .toggle : .other }
        switch keyCode {
        case 126: return .up
        case 125: return .down
        case 36, 76: return .enter
        case 53: return .escape
        default:
            if let number = Int(characters), (1...9).contains(number) { return .digit(number) }
            return .other
        }
    }
}
