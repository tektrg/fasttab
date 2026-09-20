import Foundation

/// What the user chose for one question of a form, before anything is sent.
enum FormChoice: Equatable, Sendable {
    /// Positions (0-based) in the question's option list.
    case options([Int])
    /// Free text for the terminal's "Type something" row.
    case other(String)
}

/// The whole multi-question card: one draft per question, and where the batch send is.
/// Pure: clicks and typing go in, "may Submit be pressed" and the choices come out. Nothing
/// is sent from here, and Submit is enabled only when EVERY question has an answer.
struct AnswerFormState: Equatable, Sendable {
    struct Draft: Equatable, Sendable {
        var pickedPositions: Set<Int> = []
        var usesOther = false
        var otherText = ""
    }

    enum SendState: Equatable, Sendable {
        case editing
        /// The batch is running; `question` is the 0-based one being handled.
        case sending(question: Int)
        /// The batch stopped or finished with something to tell (see `report`).
        case stopped
    }

    let form: PendingQuestionForm
    private(set) var drafts: [Draft]
    private(set) var outcomes: [FormQuestionOutcome]
    private(set) var sendState: SendState = .editing
    /// The words for a batch that stopped.
    private(set) var report: String?

    init(form: PendingQuestionForm) {
        self.form = form
        drafts = Array(repeating: Draft(), count: form.questions.count)
        outcomes = Array(repeating: .waiting, count: form.questions.count)
    }

    // MARK: - Editing

    /// The Other row of question `question` sits after its options.
    func otherRow(of question: Int) -> Int { form.questions[question].options.count }

    var isEditable: Bool { sendState == .editing }

    /// A click on `row` of `question`: an option (radio for single-select, tick for multi-select) or the Other row.
    /// Choosing Other drops ticks and ticking an option drops Other: the dashboard sends either text or options, not both.
    mutating func click(row: Int, of question: Int) {
        guard isEditable, form.questions.indices.contains(question), (0...otherRow(of: question)).contains(row) else { return }
        var draft = drafts[question]
        if row == otherRow(of: question) {
            draft.usesOther = true
            draft.pickedPositions = []
        } else {
            draft.usesOther = false
            if form.questions[question].isMultiSelect {
                if !draft.pickedPositions.insert(row).inserted { draft.pickedPositions.remove(row) }
            } else {
                draft.pickedPositions = [row]
            }
        }
        drafts[question] = draft
    }

    mutating func setOtherText(_ text: String, of question: Int) {
        guard isEditable, drafts.indices.contains(question) else { return }
        drafts[question].otherText = text
    }

    func isChecked(row: Int, of question: Int) -> Bool {
        row == otherRow(of: question) ? drafts[question].usesOther : drafts[question].pickedPositions.contains(row)
    }

    // MARK: - Answers

    /// The choice for `question`; nil while it is unanswered (nothing ticked, or Other with no text).
    func choice(for question: Int) -> FormChoice? {
        let draft = drafts[question]
        if draft.usesOther { return OtherAnswerText.sendable(draft.otherText).map(FormChoice.other) }
        return draft.pickedPositions.isEmpty ? nil : .options(draft.pickedPositions.sorted())
    }

    var answeredCount: Int { drafts.indices.filter { choice(for: $0) != nil }.count }
    var isComplete: Bool { answeredCount == drafts.count }
    /// Submit is live: everything answered and nothing already on its way.
    var canSubmit: Bool { isEditable && isComplete }

    /// Every question's choice, in order; nil unless all are answered.
    var choices: [FormChoice]? {
        let all = drafts.indices.compactMap(choice(for:))
        return all.count == drafts.count ? all : nil
    }

    // MARK: - Sending

    mutating func beginSending() {
        guard canSubmit else { return }
        sendState = .sending(question: 0)
    }

    mutating func record(_ outcome: FormQuestionOutcome, for question: Int) {
        guard outcomes.indices.contains(question) else { return }
        outcomes[question] = outcome
        if outcome == .sending { sendState = .sending(question: question) }
    }

    /// The batch stopped: the card stays so the user can read exactly what landed.
    mutating func stop(result: FormBatchResult, report: String) {
        outcomes = result.outcomes
        self.report = report
        sendState = .stopped
    }
}
