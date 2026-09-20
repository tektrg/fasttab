import Foundation

/// How patient the batch send is. Tests use no pause.
struct FormBatchTiming: Sendable {
    /// Reads of the pane per step before giving up on it moving to the expected question.
    var readsPerStep = 6
    /// Reads for the very first step: nothing has changed yet, waiting does not help.
    var readsForFirstStep = 2
    var pauseBetweenReadsSeconds: TimeInterval = 0.7
    /// Looks at the transcript for the form's recorded answers when the pane shows no question (its result line
    /// lags the terminal by a moment), and how long to wait between looks.
    var transcriptLooks = 3
    var pauseBetweenTranscriptLooksSeconds: TimeInterval = 1
    /// The whole batch, per question: one number covers reads, answers and waiting.
    var budgetSecondsPerQuestion: TimeInterval = 40
    /// After the last answer the dashboard presses Submit itself; a moment for that to settle.
    var pause: @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(for: .seconds($0)) }
}

/// Answers every question of a form, one after another, through the dashboard's one-question
/// endpoint. NOT atomic: each answer is typed into the terminal for real, so a stop halfway leaves the
/// earlier ones landed. It never retries and never resends a question (a resend would untick a multi-select).
///
/// For each question: read the pane (read-only) -> decide which question is on screen -> verify the option
/// labels against the pane -> POST that one answer -> the next step's read confirms the pane moved on.
/// After the last question the dashboard presses "Submit answers" itself.
struct FormBatchDriver: Sendable {
    let paneId: String
    let form: PendingQuestionForm
    let choices: [FormChoice]
    let source: any AgentStatusSource
    var timing = FormBatchTiming()
    /// The agent's own record of what the form received, once it was submitted (nil = cannot tell).
    var recordedAnswers: @Sendable (PendingQuestionForm) async -> RecordedFormAnswers? = { _ in nil }
    /// Reports each question's progress as it happens.
    let progress: @Sendable @MainActor (Int, FormQuestionOutcome) -> Void

    func run() async -> FormBatchResult {
        var outcomes = [FormQuestionOutcome](repeating: .waiting, count: form.questions.count)
        var seen: [QuestionIdentity] = []
        var finalNext: AnswerableQuestion?
        var expected = 0
        let deadline = Date().addingTimeInterval(timing.budgetSecondsPerQuestion * Double(form.questions.count))

        /// Everything not yet handled becomes "not sent", with the reason.
        func stopped(_ rawReason: String) async -> FormBatchResult {
            let reason = rawReason.capitalizedFirst
            for index in outcomes.indices where outcomes[index] == .waiting || outcomes[index] == .sending {
                outcomes[index] = .notSent(reason)
                await progress(index, outcomes[index])
            }
            return FormBatchResult(outcomes: outcomes, stopReason: reason, finalNext: finalNext, seenIdentities: seen)
        }

        while expected < form.questions.count {
            let step = await observeUntilAnswerable(expected: expected, deadline: deadline)
            switch step {
            case .stop(let reason): return await stopped(reason)
            case .paneShowsNoQuestion(let reason):
                if let recorded = await lookUpRecordedAnswers() { return recordedResult(recorded, outcomes: outcomes, seen: seen) }
                return await stopped(reason)
            case .ready(let index, let skipped, let pane):
                for skippedIndex in skipped {
                    outcomes[skippedIndex] = .skipped("the terminal had already moved past it. If it was not answered there, answer it in the terminal.")
                    await progress(skippedIndex, outcomes[skippedIndex])
                }
                seen.append(pane.identity)
                let choice: AnswerChoice
                switch FormBatchPlanner.answerChoice(for: choices[index], question: form.questions[index], pane: pane) {
                case .failure(let error): return await stopped(error.reason)
                case .success(let built): choice = built
                }
                outcomes[index] = .sending
                await progress(index, .sending)
                let result = await source.answer(paneId: paneId, choice: choice, question: pane.identity)
                switch result {
                case .failed where Task.isCancelled:
                    return await stopped("timed out. The request for \(FormBatchReport.name(of: index, in: form)) may or may not have landed: check the terminal.")
                case .failed(let message):
                    outcomes[index] = .refused(message)
                    await progress(index, outcomes[index])
                    return await stopped("the dashboard refused \(FormBatchReport.name(of: index, in: form)).")
                case .sent(let next):
                    outcomes[index] = .landed
                    await progress(index, .landed)
                    finalNext = next
                    expected = index + 1
                }
            }
        }
        return FormBatchResult(outcomes: outcomes, stopReason: nil, finalNext: finalNext, seenIdentities: seen)
    }

    private enum Step {
        case ready(question: Int, skipped: [Int], pane: AnswerableQuestion)
        case stop(String)
        /// The last read showed no question at all (form submitted, or gone): the transcript may say which.
        case paneShowsNoQuestion(String)
    }

    /// The transcript's result line can lag the terminal: a few looks, spaced out.
    private func lookUpRecordedAnswers() async -> RecordedFormAnswers? {
        for look in 0..<timing.transcriptLooks {
            if Task.isCancelled { return nil }
            if let recorded = await recordedAnswers(form) { return recorded }
            if look < timing.transcriptLooks - 1 { await timing.pause(timing.pauseBetweenTranscriptLooksSeconds) }
        }
        return nil
    }

    /// The form is done: every question shows what the agent received, and the user's draft is compared with it.
    private func recordedResult(_ recorded: RecordedFormAnswers, outcomes: [FormQuestionOutcome], seen: [QuestionIdentity]) -> FormBatchResult {
        var updated = outcomes
        for index in updated.indices {
            guard let answer = recorded.answers[index] else { updated[index] = .notSent("the transcript has no recorded answer for it"); continue }
            let matches = RecordedFormAnswers.draftMatches(choices[index], question: form.questions[index], recorded: answer)
            updated[index] = .recorded(answer: answer, chose: matches ? nil : RecordedFormAnswers.words(for: choices[index], question: form.questions[index]))
        }
        return FormBatchResult(outcomes: updated, stopReason: "the form was submitted", finalNext: nil, seenIdentities: seen)
    }

    /// Reads the pane until it shows a question that can be answered, a bounded number of times.
    private func observeUntilAnswerable(expected: Int, deadline: Date) async -> Step {
        let reads = expected == 0 ? timing.readsForFirstStep : timing.readsPerStep
        var lastWait = "nothing was read"
        var lastReadShowedNoQuestion = false
        for attempt in 0..<reads {
            if Task.isCancelled || Date() > deadline { return .stop("timed out waiting for the terminal.") }
            let observed = await observation()
            lastReadShowedNoQuestion = observed == .noQuestion
            switch FormBatchPlanner.decide(observed, form: form, expected: expected) {
            case .answer(let question, let skipped):
                guard case .question(let pane) = observed else { continue }
                return .ready(question: question, skipped: skipped, pane: pane)
            case .stop(let reason): return .stop(reason)
            case .waitForPane(let reason):
                lastWait = reason
                if attempt < reads - 1 { await timing.pause(timing.pauseBetweenReadsSeconds) }
            }
        }
        return lastReadShowedNoQuestion ? .paneShowsNoQuestion(lastWait) : .stop(lastWait)
    }

    private func observation() async -> FormBatchPlanner.Observation {
        switch await source.paneScreen(paneId: paneId) {
        case .failure(let message): return .unreadable(message)
        case .screen(let lines, _):
            switch PaneQuestionReader.openPickerState(in: lines) {
            case .open(let question): return .question(question)
            case .onExitRow(let identity), .hasTicks(let identity): return .beingAnswered(identity)
            case .unparsed, .review, .none: return .noQuestion
            }
        }
    }
}
