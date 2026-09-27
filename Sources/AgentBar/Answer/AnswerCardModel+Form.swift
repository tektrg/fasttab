import Foundation

/// The multi-question side of the answer card: turning the card into a form when the
/// agent's transcript says the question is one tab of a form, holding the drafts, and
/// running the batch send. The single-question card is untouched by all of this: any doubt
/// (no session, no transcript, no matching form) leaves it exactly as it was.
extension AnswerCardModel {
    // MARK: - Opening as a form

    /// Reads the transcript for a pending form; the card turns into the form card when one is found
    /// and the question in front of the agent is one of its questions.
    func loadPendingFormForCard() {
        guard let card, let sessionId = card.sessionId else { return }
        let agentID = card.agentID
        let load = loadPendingForm
        formLoader.load({ await load(sessionId) }) { [weak self] form in
            self?.adoptForm(form, forAgent: agentID)
        }
    }

    private func adoptForm(_ form: PendingQuestionForm?, forAgent agentID: String) {
        guard var card, card.agentID == agentID, card.form == nil, let form,
              form.questions.count >= PendingQuestionForm.minimumQuestionCount,
              form.indexOfQuestion(matching: card.state.question.question) != nil else { return }
        card.form = AnswerFormState(form: form)
        self.card = card
    }

    // MARK: - Editing

    /// A click on option `row` of question `question` (the Other row is the one after the options).
    func clickFormRow(_ row: Int, of question: Int) {
        guard var card, card.form != nil else { return }
        card.form?.click(row: row, of: question)
        self.card = card
    }

    func setFormOtherText(_ text: String, of question: Int) {
        card?.form?.setOtherText(text, of: question)
    }

    /// Esc in a question's text field: the keyboard goes back to the search field, so the next Esc closes the card.
    func releaseFormTextField() {
        onReleaseKeyboard()
    }

    /// Keys while the form is showing: it is a mouse card. Enter submits when every question is answered;
    /// Esc goes back to the list.
    func handleFormKey(_ key: AnswerCardState.Key) {
        guard card?.form != nil else { return }
        switch key {
        case .escape:
            close()
        case .enter, .send:
            submitForm()
        case .digit, .up, .down, .space, .leaveTypingUp, .leaveTypingDown:
            break
        }
    }

    // MARK: - Sending

    /// Submit: only with every question answered. The card closes at once, like a single answer's, and the questions
    /// go out one after another in the background (see `FormBatchDriver`); the row counts as sending until the
    /// dashboard catches up, and a batch that stops reports to the footer notice.
    private func submitForm() {
        guard let card, let form = card.form?.form, card.form?.canSubmit == true,
              let choices = card.form?.choices, let statusSource else { return }
        if let hookRequest = card.hookRequest {
            submitHookForm(hookRequest, card: card, choices: choices, source: statusSource)
            return
        }
        guard let token = tracker.begin(agentID: card.agentID, at: now()) else { return }
        close()
        let agentID = card.agentID
        let fallbackIdentity = card.state.question.identity
        let sessionId = card.sessionId
        let loadRecorded = loadRecordedAnswers
        let driver = FormBatchDriver(
            paneId: card.paneId, form: form, choices: choices, source: statusSource, timing: formTiming,
            recordedAnswers: { form in
                guard let sessionId else { return nil }
                return await loadRecorded(sessionId, form)
            },
            progress: { [weak self] question, outcome in self?.recordFormProgress(outcome, question: question, formID: form.toolUseId) }
        )
        let task = Task { [weak self] in
            let result = await driver.run()
            self?.finishBatch(result, form: form, token: token, agentID: agentID, fallbackIdentity: fallbackIdentity)
        }
        batchTasks[agentID] = task
        // The whole batch has one time budget: past it the driver's next step sees the cancellation and stops.
        // The watchdog holds its own batch's task: another agent's batch is never its to cancel.
        let budget = formTiming.budgetSecondsPerQuestion * Double(form.questions.count)
        batchWatchdogs[agentID] = Task {
            try? await Task.sleep(for: .seconds(budget + 5))
            guard !Task.isCancelled else { return }
            task.cancel()
        }
    }

    private func recordFormProgress(_ outcome: FormQuestionOutcome, question: Int, formID: String) {
        guard card?.form?.form.toolUseId == formID else { return }
        card?.form?.record(outcome, for: question)
    }

    private func finishBatch(_ result: FormBatchResult, form: PendingQuestionForm, token: Int, agentID: String, fallbackIdentity: QuestionIdentity) {
        batchWatchdogs.removeValue(forKey: agentID)?.cancel()
        batchTasks[agentID] = nil
        let report = FormBatchReport.summary(result, form: form)
        let cardShowsForm = card?.form?.form.toolUseId == form.toolUseId
        if result.isComplete {
            let answered = Set(result.seenIdentities)
            guard tracker.succeeded(
                agentID: agentID, token: token, identity: result.seenIdentities.last ?? fallbackIdentity,
                alsoAnswered: answered, next: result.finalNext, at: now()
            ) else { return }
            if cardShowsForm { close() }
            scheduleRefresh(after: AnswerSendTracker.expirySeconds)
            if result.outcomes.contains(where: { if case .skipped = $0 { true } else { false } }) { onNotice(report) }
            if result.finalNext == nil { onAnswered(agentID) }
        } else {
            // Some answers are already typed into the terminal: the card stays with the exact report, and never offers a resend.
            _ = tracker.expire(agentID: agentID, token: token)
            if cardShowsForm { card?.form?.stop(result: result, report: report) }
            onNotice(report)
        }
        objectWillChange.send()
    }

    /// The old dashboard's agents are gone: nothing of a running batch is worth reporting.
    func cancelBatch() {
        batchTasks.values.forEach { $0.cancel() }
        batchWatchdogs.values.forEach { $0.cancel() }
        batchTasks = [:]
        batchWatchdogs = [:]
    }
}
