import Foundation

/// How the plan card reads a plan file: off the main thread, given the path exactly as the box drew it.
typealias PlanFileLoad = @Sendable (_ path: String?) async -> PlanFile

/// The plan-approval half of the permission card's model (Claude's plan mode). The card is the same
/// one (agent, last message, the pane read before anything is decided); its rows are the box's own,
/// and choosing one sends `choice: "select"` with the row's number and the box as the pane shows it.
///
/// Safety rules, on top of `PlanCardState`'s: the pane is read again at the moment of sending and
/// nothing goes out unless the box (file and row wording) is still the one on the card; the dashboard
/// then checks it once more before pressing anything. Nothing is ever retried: a timeout says the
/// answer may have gone through.
extension PermissionCardModel {
    // MARK: - Keys and clicks

    func handlePlanKey(_ key: PermissionCardState.Key) {
        guard var card, var plan = card.plan else { return }
        let wasTyping = plan.isTypingFeedback
        let effect = plan.handle(key)
        card.plan = plan
        self.card = card
        switch effect {
        case .none: break
        case .close: close()
        case .send(let selection): sendPlan(selection)
        }
        if wasTyping, self.card?.plan?.isTypingFeedback != true { onReleaseKeyboard() }
    }

    /// A click on one of the box's rows: highlights it (the feedback row opens its text box).
    func clickPlanOption(index: Int) {
        guard var card, var plan = card.plan else { return }
        let wasTyping = plan.isTypingFeedback
        plan.clickOption(index: index)
        card.plan = plan
        self.card = card
        if wasTyping, !plan.isTypingFeedback { onReleaseKeyboard() }
    }

    func setFeedbackText(_ text: String) {
        card?.plan?.feedbackText = text
    }

    // MARK: - The plan file

    func loadPlanFileIfNeeded() {
        guard let plan = card?.plan, let agentID = card?.agentID else { return }
        let path = plan.prompt.planPath
        card?.planFileRequestedPath = path
        guard path != nil else {
            planFileLoader.cancel()
            card?.planFile = .noPath
            return
        }
        card?.planFile = .loading
        let load = loadPlanFile
        planFileLoader.load({ await load(path) }) { [weak self] file in
            guard self?.card?.agentID == agentID, self?.card?.planFileRequestedPath == path else { return }
            self?.card?.planFile = file
        }
    }

    /// The pane may name another plan file than the feed did: the plan shown is the pane's.
    func reloadPlanFileIfPathChanged() {
        guard let card, let plan = card.plan, plan.phase == .ready,
              plan.prompt.planPath != card.planFileRequestedPath else { return }
        loadPlanFileIfNeeded()
    }

    // MARK: - Sending

    static func planSendingLabel(forTag tag: String) -> String? {
        switch tag {
        case PlanSend.answerTag: "Sending your answer…"
        case PlanSend.feedbackTag: "Sending feedback…"
        default: nil
        }
    }

    /// The press that sends: the card closes at once, the pane is read again, and the row goes out
    /// only if the box is still the one on the card.
    func sendPlan(_ selection: PlanCardState.Selection) {
        guard let card, let statusSource, let plan = card.plan, plan.phase == .ready else { return }
        let prompt = plan.prompt
        let agentID = card.agentID
        let paneId = card.paneId
        let tag = selection.feedback == nil ? PlanSend.answerTag : PlanSend.feedbackTag
        guard let token = tracker.begin(agentID: agentID, tag: tag, at: now()) else { return }
        close()
        scheduleExpiry(agentID: agentID, token: token)
        Task { [weak self] in
            let result = await PlanSend.deliver(selection, to: paneId, expecting: prompt, through: statusSource)
            self?.finishPlanSend(result, token: token, agentID: agentID, prompt: prompt, selection: selection)
        }
    }

    private func finishPlanSend(
        _ result: PermissionResult, token: Int, agentID: String, prompt: PermissionPrompt, selection: PlanCardState.Selection
    ) {
        let decision = PermissionDecision(identity: prompt.identity, planRowIndex: selection.option.index)
        let noun = selection.feedback == nil ? "Plan answer" : "Plan feedback"
        switch result {
        case .failed(let message):
            guard tracker.failed(agentID: agentID, token: token, draft: decision) else { return }
            onNotice("\(noun) not sent: \(message)")
        case .unsupported(let reply):
            guard tracker.failed(agentID: agentID, token: token, draft: decision) else { return }
            onNotice("\(noun) not sent: the dashboard replied \"\(reply)\". It may need a restart to answer plans; use Open terminal meanwhile.")
        case .sent(let next, let warning):
            if let warning { reportWarning(PlanSend.autoModeWarningSentence(warning), agentID: agentID) }
            guard tracker.succeeded(agentID: agentID, token: token, identity: prompt.identity, next: next, at: now()) else { return }
            scheduleRefresh(after: PermissionSendTracker.expirySeconds)
            if next == nil { onDecided(agentID) }
        }
        objectWillChange.send()
    }
}

/// The wire side of a plan answer: the last look at the pane, then one `select`.
enum PlanSend {
    static let answerTag = "plan"
    static let feedbackTag = "plan-feedback"
    /// The dashboard's own warning (the pane shows auto mode after a choice that was not auto mode), in a sentence.
    static func autoModeWarningSentence(_ warning: String) -> String {
        "Sent, but the agent now shows auto mode: \(PermissionCardModel.withoutTrailingPeriod(warning)). Check the terminal."
    }
    static let promptChangedMessage = "Nothing was sent: the plan prompt in the terminal changed since this card was opened. Open it again."

    /// Reads the pane; sends only when it still shows the box the card showed (same file, same rows,
    /// same words), and then with the pane's own copy of the box. Any doubt is a refusal, never a guess.
    static func deliver(
        _ selection: PlanCardState.Selection, to paneId: String, expecting expected: PermissionPrompt, through source: any AgentStatusSource
    ) async -> PermissionResult {
        switch await source.paneScreen(paneId: paneId) {
        case .failure(let message):
            return .failed("Nothing was sent: the terminal could not be checked first (\(message)).")
        case .screen(let lines, _):
            guard let live = PanePermissionReader.prompt(in: lines), live.isPlan,
                  live.identity == expected.identity, live.options == expected.options else {
                return .failed(promptChangedMessage)
            }
            return await source.selectPlanOption(
                paneId: paneId, index: selection.option.index, text: selection.feedback, permission: live
            )
        }
    }
}
