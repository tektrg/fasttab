import Foundation

/// Observable state behind the permission card: opens it on a blocked agent's permission
/// box, reads the box from the pane (what is decided is what the pane shows, not the feed's
/// possibly wrapped or lagging copy), feeds it keys, sends the decision the user chose, and
/// keeps the card in step with the dashboard. Key rules live in the pure `PermissionCardState`.
///
/// Safety rules: nothing is sent before the pane has been read; a decision is sent only from
/// a key or click that means "send", once per decision (a refusal is shown, never retried),
/// and always with the box the pane showed, so the dashboard refuses if the pane moved on.
@MainActor
final class PermissionCardModel: ObservableObject {
    static let alreadyDecidedMessage = "Already decided. Waiting for the dashboard to catch up."
    static let noReplyMessage = "No reply from the dashboard to your decision yet. Check the agent's terminal: it may have gone through."
    static let noSourceMessage = "No status dashboard to send the decision to."
    static let notReadableMessage = "AgentBar can't read this prompt in the terminal (it may have been decided already, or its layout is not one AgentBar handles). Open the terminal."
    /// How long a dashboard that had no /api/permission is remembered as such.
    static let endpointMissingSeconds: TimeInterval = 120

    /// The open card. Written only by this model and its plan extension (`PermissionCardModel+Plan`).
    @Published var card: PermissionCard?

    /// Where decisions go; set by the host, replaced with the dashboard address.
    var statusSource: (any AgentStatusSource)?
    /// A sentence for the panel's footer (a decision that never reached the pane).
    var onNotice: (String) -> Void = { _ in }
    /// A sentence for the footer that is not a failure: the answer went through but the pane ended up
    /// somewhere the user should check (orange, closable).
    var onWarning: (String) -> Void = { _ in }
    /// The box was decided and nothing follows it: the host moves on.
    var onDecided: (_ agentID: String) -> Void = { _ in }
    /// The dashboard has no permission endpoint: the host re-derives its rows.
    var onEndpointMissing: () -> Void = {}
    /// The card's way out when the box cannot be decided from here.
    var onOpenTerminal: (_ agentID: String) -> Void = { _ in }

    /// The plan card's text box gave the keyboard back: the host refocuses the search field.
    var onReleaseKeyboard: () -> Void = {}

    private let loadSessionContext: AnswerCardModel.SessionContextLoad
    private let contextLoader = LatestResultLoader<SessionContext>()
    private let screenLoader = LatestResultLoader<PaneScreenResult>()
    // Shared with the plan card's half of the model (`PermissionCardModel+Plan`).
    let loadPlanFile: PlanFileLoad
    let planFileLoader = LatestResultLoader<PlanFile>()
    var tracker = PermissionSendTracker()
    private var endpointMissingUntil: Date?
    let now: () -> Date
    let sendExpirySeconds: TimeInterval

    init(
        now: @escaping () -> Date = Date.init,
        sendExpirySeconds: TimeInterval = PermissionSendTracker.expirySeconds,
        loadSessionContext: @escaping AnswerCardModel.SessionContextLoad = AnswerCardModel.readTranscript,
        loadPlanFile: @escaping PlanFileLoad = PlanFileReader.load
    ) {
        self.now = now
        self.sendExpirySeconds = sendExpirySeconds
        self.loadSessionContext = loadSessionContext
        self.loadPlanFile = loadPlanFile
    }

    var isOpen: Bool { card != nil }

    // MARK: - Opening and closing

    /// Opens the card on `agent`'s permission box and reads the pane. Returns false (with a
    /// reason for the footer, when there is one) when it cannot be decided from here.
    @discardableResult
    func open(_ agent: AgentSnapshot) -> Bool {
        guard case .permissionReview(let shown)? = agent.blockedOnYou, let paneId = agent.paneId, !paneId.isEmpty else {
            return false
        }
        guard let statusSource else {
            onNotice(Self.noSourceMessage)
            return false
        }
        guard !isAwaiting(agent) else { return false }
        var prompt = shown
        if tracker.hasAnswered(agentID: agent.id, shown.identity) {
            guard let next = tracker.nextQuestion(agentID: agent.id, after: shown.identity) else {
                onNotice(Self.alreadyDecidedMessage)
                return false
            }
            prompt = next
        }
        close()
        card = PermissionCard(agent: agent, paneId: paneId, prompt: prompt)
        loadContext()
        loadPlanFileIfNeeded()
        readPane(paneId: paneId, agentID: agent.id, source: statusSource)
        return true
    }

    func close() {
        contextLoader.cancel()
        screenLoader.cancel()
        planFileLoader.cancel()
        card = nil
    }

    /// Forgets everything about the old dashboard's agents.
    func reset() {
        close()
        tracker.reset()
        endpointMissingUntil = nil
    }

    // MARK: - Keys and clicks

    func handle(_ key: PermissionCardState.Key) {
        guard var card else { return }
        if card.plan != nil {
            handlePlanKey(key)
            return
        }
        let effect = card.state.handle(key)
        self.card = card
        switch effect {
        case .none: break
        case .close: close()
        case .send(let choice): send(choice)
        }
    }

    func clickChoice(_ choice: PermissionChoice) {
        guard var card else { return }
        card.state.clickChoice(choice)
        self.card = card
    }

    /// The card's action button.
    func pressSend() {
        handle(.send)
    }

    func openTerminal() {
        guard let agentID = card?.agentID else { return }
        onOpenTerminal(agentID)
    }

    // MARK: - Reading the pane

    /// Reads the pane (read-only) so the decision is sent for the box exactly as the dashboard reads it.
    private func readPane(paneId: String, agentID: String, source: any AgentStatusSource) {
        screenLoader.load({ await source.paneScreen(paneId: paneId) }) { [weak self] result in
            guard let self, var card = self.card, card.agentID == agentID else { return }
            switch result {
            case .screen(let lines, _):
                var live = PanePermissionReader.prompt(in: lines)
                if let box = live, self.tracker.hasAnswered(agentID: agentID, box.identity),
                   self.tracker.nextQuestion(agentID: agentID, after: box.identity) == nil {
                    live = nil   // the box just decided, still on screen a moment: not to be decided twice
                }
                card.resolve(live: live, failure: live == nil ? Self.notReadableMessage : nil)
            case .failure(let message):
                card.resolve(live: nil, failure: message)
            }
            self.card = card
            self.reloadPlanFileIfPathChanged()
        }
    }

    // MARK: - Sending

    /// The action press: the card closes at once and the decision goes out in the
    /// background; the row shows "Sending approval…" until it is settled.
    private func send(_ choice: PermissionChoice) {
        guard let card, let statusSource, card.plan == nil, card.state.phase == .ready else { return }
        let prompt = card.state.prompt
        let agentID = card.agentID
        let paneId = card.paneId
        guard let token = tracker.begin(agentID: agentID, tag: choice.flightTag, at: now()) else { return }
        close()
        scheduleExpiry(agentID: agentID, token: token)
        Task { [weak self] in
            let result = await statusSource.permission(paneId: paneId, choice: choice, permission: prompt)
            self?.finishSend(result, token: token, agentID: agentID, prompt: prompt, choice: choice)
        }
    }

    private func finishSend(_ result: PermissionResult, token: Int, agentID: String, prompt: PermissionPrompt, choice: PermissionChoice) {
        let decision = PermissionDecision(identity: prompt.identity, choice: choice)
        let noun = choice == .deny ? "Denial" : "Approval"
        switch result {
        case .failed(let message):
            guard tracker.failed(agentID: agentID, token: token, draft: decision) else { return }
            onNotice("\(noun) not sent: \(message)")
        case .unsupported(let reply):
            guard tracker.failed(agentID: agentID, token: token, draft: decision) else { return }
            endpointMissingUntil = now().addingTimeInterval(Self.endpointMissingSeconds)
            onNotice("\(noun) not sent: the dashboard replied \"\(reply)\". It may need a restart to take approvals; use Open terminal meanwhile.")
            onEndpointMissing()
        case .sent(let next, let warning):
            // The key went out: a dashboard warning is told even when the send record is stale.
            if let warning { reportWarning("Sent, but the dashboard warned: \(warning.withoutTrailingPeriod). Check the terminal.", agentID: agentID) }
            guard tracker.succeeded(agentID: agentID, token: token, identity: prompt.identity, next: next, at: now()) else { return }
            scheduleRefresh(after: PermissionSendTracker.expirySeconds)
            if next == nil { onDecided(agentID) }
        }
        objectWillChange.send()
    }

    /// Never swallowed: the footer says it, and a card open for that agent (a revised plan's, say) carries it too.
    func reportWarning(_ sentence: String, agentID: String) {
        onWarning(sentence)
        if card?.agentID == agentID { card?.sentWarning = sentence }
    }



    /// A send with no reply in time frees its row and says so; the decision may still have gone through.
    func scheduleExpiry(agentID: String, token: Int) {
        Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(self.sendExpirySeconds))
            guard self.tracker.expire(agentID: agentID, token: token) else { return }
            self.onNotice(Self.noReplyMessage)
            self.objectWillChange.send()
        }
    }

    /// Redraws once the "awaiting the dashboard" window has passed.
    func scheduleRefresh(after seconds: TimeInterval) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds + 0.1))
            self?.objectWillChange.send()
        }
    }

    // MARK: - Rows

    /// What the row says instead of its buttons while its decision is on its way; nil when nothing is.
    func sendingLabel(for agent: AgentSnapshot) -> String? {
        var shown: PermissionIdentity?
        if case .permissionReview(let prompt)? = agent.blockedOnYou { shown = prompt.identity }
        guard let tag = tracker.awaitingTag(agentID: agent.id, showing: shown, now: now()) else { return nil }
        if let planLabel = Self.planSendingLabel(forTag: tag) { return planLabel }
        return tag == PermissionChoice.deny.flightTag ? PermissionChoice.deny.sendingLabel : PermissionChoice.allow.sendingLabel
    }

    func isAwaiting(_ agent: AgentSnapshot) -> Bool { sendingLabel(for: agent) != nil }

    /// While the dashboard is known to lack the permission endpoint, a box is terminal-only:
    /// its Review is turned back into Open terminal (for `endpointMissingSeconds`).
    func withoutReviewIfEndpointMissing(_ agents: [AgentSnapshot]) -> [AgentSnapshot] {
        guard let until = endpointMissingUntil, now() < until else { return agents }
        return agents.map { agent in
            guard case .permissionReview? = agent.blocker else { return agent }
            return agent.withBlocker(.permission)
        }
    }

    // MARK: - Following the dashboard

    /// Every status update: forgets boxes the dashboard no longer shows, and closes the card
    /// when the agent is no longer blocked on a permission box. The dashboard's copy can be
    /// ~15s behind and flaps between parsed and plain, so a different or plain box does not
    /// replace what the pane was read to say.
    func reconcile(with agents: [AgentSnapshot]) {
        var current: [String: PermissionIdentity] = [:]
        for agent in agents {
            if case .permissionReview(let prompt)? = agent.blockedOnYou { current[agent.id] = prompt.identity }
        }
        tracker.settle(currentQuestions: current)
        guard let card else { return }
        let agent = agents.first { $0.id == card.agentID }
        switch agent?.blockedOnYou {
        case .permissionReview?, .permission?:
            refreshPaneId(from: agent)
        case .question?, .questionLoading?, .questionNotAnswerable?, nil:
            close()
        }
    }

    /// herdr can reassign a still-live session's pane id while the card sits open (a "pane not
    /// found" send against a pane the user can see is alive, not a closed one — see the
    /// AptusFit remote-herdr delivery record, rule R6: identity is the session, not the pane id).
    /// Keeps `card.paneId` current so a send lands on where the agent's box actually is now;
    /// nothing else on the card moves off what the pane was read to say.
    private func refreshPaneId(from agent: AgentSnapshot?) {
        guard let paneId = agent?.paneId, !paneId.isEmpty, paneId != card?.paneId else { return }
        card?.paneId = paneId
    }

    // MARK: - Transcript

    private func loadContext() {
        guard let sessionId = card?.sessionId, let agentID = card?.agentID else { return }
        let load = loadSessionContext
        contextLoader.load({ await load(sessionId) }) { [weak self] context in
            guard self?.card?.agentID == agentID else { return }
            self?.card?.sessionContext = context
        }
    }
}

extension String {
    /// Trimmed, without trailing periods, so a dashboard warning reads inside a sentence.
    /// A `String` extension (not a static on the main-actor model): Swift 6.2's compiler rejects
    /// calling a `nonisolated static` of a `@MainActor` type from a nonisolated enum.
    var withoutTrailingPeriod: String {
        var trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix(".") { trimmed.removeLast() }
        return trimmed
    }
}
