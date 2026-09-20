import Foundation

/// The pure decisions of a batch send: which question is on screen, may it be answered,
/// and which option numbers the terminal's own picker gives the options the user chose.
enum FormBatchPlanner {
    /// What one read of the pane showed.
    enum Observation: Equatable, Sendable {
        case question(AnswerableQuestion)
        /// No picker: the review screen, the form gone, or a screen mid-redraw.
        case noQuestion
        /// A picker is open but someone is answering it in the terminal right now (the cursor is on its
        /// exit row, or options are already ticked). Never typed into.
        case beingAnswered(QuestionIdentity)
        case unreadable(String)
    }

    enum Decision: Equatable, Sendable {
        /// Answer the form's question `question` now; `skipped` are the earlier ones the terminal has moved past.
        case answer(question: Int, skipped: [Int])
        /// Not yet: look again shortly (the reason is what to say if it never changes).
        case waitForPane(String)
        /// Never going to work: stop with this reason.
        case stop(String)
    }

    static let noQuestionReason = "no question is showing in the terminal (it may be on the review screen, or it may already be submitted or being answered in the terminal)"

    /// `expected` is the first question not yet handled. The terminal showing a later one means the
    /// earlier ones were answered there meanwhile (skipped, and reported as such); showing an earlier,
    /// already sent one means it has not moved on yet.
    static func decide(_ observation: Observation, form: PendingQuestionForm, expected: Int) -> Decision {
        switch observation {
        case .unreadable(let message):
            return .waitForPane("the terminal could not be read (\(message))")
        case .noQuestion:
            return .waitForPane(Self.noQuestionReason)
        case .beingAnswered(let identity):
            // The question just answered can be drawn once more, ticked, while the terminal redraws: wait that out.
            guard let shown = form.indexOfQuestion(matching: identity.question) else {
                return .stop("the terminal shows a question that is not part of this form: \"\(QuestionDisplayText.clean(identity.question))\"")
            }
            if shown < expected { return .waitForPane("the terminal did not move on from \(FormBatchReport.name(of: shown, in: form))") }
            return .stop("this question is already being answered in the terminal (\(FormBatchReport.name(of: shown, in: form))). Nothing was typed into it")
        case .question(let pane):
            guard let shown = form.indexOfQuestion(matching: pane.question) else {
                return .stop("the terminal shows a question that is not part of this form: \"\(pane.displayQuestion)\"")
            }
            if shown < expected {
                return .waitForPane("the terminal did not move on from \(FormBatchReport.name(of: shown, in: form))")
            }
            return .answer(question: shown, skipped: Array(expected..<shown))
        }
    }

    /// What to send for `choice` given the picker the pane shows: the option numbers are the pane's own,
    /// found by label (never assumed from position), and every label must be there. `.failure` carries the reason.
    static func answerChoice(for choice: FormChoice, question: FormQuestion, pane: AnswerableQuestion) -> Result<AnswerChoice, PlanError> {
        switch choice {
        case .other(let text):
            guard pane.options.contains(where: \.isOther) else { return .failure(.init("the terminal's picker has no free-text row")) }
            guard let sendable = OtherAnswerText.sendable(text) else { return .failure(.init("the typed answer is empty")) }
            return .success(.text(sendable))
        case .options(let positions):
            var indices: [Int] = []
            for position in positions {
                let label = question.options[position].label
                guard let match = paneOption(labelled: label, in: pane.options) else {
                    return .failure(.init("the option \"\(label)\" is not among the terminal's options, or could be more than one of them"))
                }
                indices.append(match.index)
            }
            return .success(.select(indices.sorted()))
        }
    }

    struct PlanError: Error, Equatable, Sendable {
        let reason: String
        init(_ reason: String) { self.reason = reason }
    }

    /// The pane row for the chosen label: the row that is exactly that label (spacing ignored), else the ONE row a
    /// label cut short by the pane's width could be. Never the first of several that merely start the same way
    /// ("Yes" starts "Yes, and remember"): nil rather than a guess.
    private static func paneOption(labelled transcriptLabel: String, in options: [AnswerableQuestion.Option]) -> AnswerableQuestion.Option? {
        let wanted = QuestionIdentity.comparable(transcriptLabel)
        guard !wanted.isEmpty else { return nil }
        let candidates = options.filter { !$0.isOther }.map { ($0, QuestionIdentity.comparable($0.label)) }.filter { !$0.1.isEmpty }
        let exact = candidates.filter { $0.1 == wanted }
        if let first = exact.first { return first.0 }
        let cutShort = candidates.filter { wanted.hasPrefix($0.1) || $0.1.hasPrefix(wanted) }
        return cutShort.count == 1 ? cutShort[0].0 : nil
    }
}
