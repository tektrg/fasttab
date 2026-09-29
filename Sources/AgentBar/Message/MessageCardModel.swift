import Foundation

/// Observable state behind the message card: opens it on a live agent, holds the draft, and
/// sends it once per press. Rules for the draft and the card's phases live in the pure
/// `MessageDraftValidator` / `MessageCard`.
///
/// Safety rules: nothing is sent unless the pane was read just before and shows neither a
/// question picker nor a permission box (typed text would answer or deny it); a message goes out
/// only from a press that means "send", one at a time per agent. A card send (`pressSend`) is
/// never retried on its own (a timeout says it may have gone through); a busy agent's message
/// needs a second press. A headless send (`sendDirect` — Jev routing, Tab-tag compose, quick
/// commands) is different: its caller sees every outcome via `onDirectSendOutcome` and, for a
/// `.failed` one (nothing reached the agent), retries it a few times before giving up — an
/// `.uncertain` one is still never retried, same double-send reason as the card.
@MainActor
final class MessageCardModel: ObservableObject {
    static let noSourceMessage = "No status dashboard to send the message to."
    static let sendingLabel = "Sending message…"
    /// How long the row says "Message sent" / "Message queued" in place of its buttons.
    static let sentLabelSeconds: TimeInterval = 6

    @Published private(set) var card: MessageCard?

    /// Where messages go; set by the host, replaced with the dashboard address.
    var statusSource: (any AgentStatusSource)?
    /// A sentence for the panel's footer (a message that never reached the agent, said after the card is gone).
    var onNotice: (String) -> Void = { _ in }
    /// Esc pressed inside the card's text field: the host may use it to close a failure notice first
    /// (true = used up, the card stays as it is).
    var consumeEscape: () -> Bool = { false }
    /// The card's text field lost the keyboard: the host gives it back to the search field.
    var onReleaseKeyboard: () -> Void = {}
    /// A `sendDirect` message actually reached the agent (Shift+Return routing, never a card
    /// send): the host records it as a row note. Not called for a failed/uncertain/needing-confirmation
    /// outcome — only a confirmed `.sent`.
    var onSentDirect: (_ agentID: String, _ text: String) -> Void = { _, _ in }
    /// Every `sendDirect` outcome (never a card send), so the host can drive its own retry —
    /// `sendDirect` only reports whether an attempt *started*, not how it landed.
    var onDirectSendOutcome: (_ agentID: String, _ label: String, _ text: String, _ outcome: MessageSendOutcome) -> Void = { _, _, _, _ in }

    private let loadSessionContext: AnswerCardModel.SessionContextLoad
    private let contextLoader = LatestResultLoader<SessionContext>()
    private let now: () -> Date
    private let sentLabelSeconds: TimeInterval
    /// Agents whose message is on its way (the row shows a spinner; the card, if open, is busy).
    private var inFlight: Set<String> = []
    private var sentLabels: [String: (text: String, until: Date)] = [:]
    /// Bumped when the dashboard changes: replies from the old one are dropped.
    private var epoch = 0

    init(
        now: @escaping () -> Date = Date.init,
        sentLabelSeconds: TimeInterval = MessageCardModel.sentLabelSeconds,
        loadSessionContext: @escaping AnswerCardModel.SessionContextLoad = AnswerCardModel.readTranscript
    ) {
        self.now = now
        self.sentLabelSeconds = sentLabelSeconds
        self.loadSessionContext = loadSessionContext
    }

    var isOpen: Bool { card != nil }

    // MARK: - Opening and closing

    /// Opens the card on `agent`. False when the row does not offer Message, or (with a reason for
    /// the footer, when there is one) when there is nowhere to send to.
    @discardableResult
    func open(_ agent: AgentSnapshot) -> Bool {
        guard RowButtons.usableButtons(for: agent).contains(.message),
              let route = MessageRoute(agent: agent), let rowId = agent.rowId, !inFlight.contains(agent.id)
        else { return false }
        guard statusSource != nil else {
            onNotice(Self.noSourceMessage)
            return false
        }
        close()
        card = MessageCard(agent: agent, route: route, rowId: rowId)
        loadContext()
        return true
    }

    /// Closes the card. A message already on its way carries on: its result still reaches the row or the footer.
    func close() {
        contextLoader.cancel()
        card = nil
    }

    /// Forgets everything about the old dashboard's agents.
    func reset() {
        epoch += 1
        close()
        inFlight = []
        sentLabels = [:]
    }

    // MARK: - Keys and clicks

    /// Every edit of the text field.
    func setDraft(_ text: String) {
        guard var card else { return }
        card.setDraft(text)
        self.card = card
    }

    /// Esc: a failure notice goes first, then the card closes (not while its message is on its way).
    func handleEscape() {
        guard let card, !consumeEscape(), card.phase == .editing else { return }
        close()
        onReleaseKeyboard()
    }

    /// Return in the text field, Enter in the list, the Send button.
    func pressSend() {
        guard var card, let statusSource, let text = card.sendableText else { return }
        let confirmed = card.isConfirming
        guard card.beginSending() else { return }
        self.card = card
        inFlight.insert(card.agentID)
        objectWillChange.send()
        let request = Request(agentID: card.agentID, label: card.label, route: card.route, rowId: card.rowId, text: text, confirmed: confirmed, notesOnSend: false)
        let epoch = epoch
        Task { [weak self] in
            let outcome = await Self.deliver(request, via: statusSource)
            self?.finishSend(outcome, of: request, epoch: epoch)
        }
    }

    /// Sends `text` straight to `agent`, with no card ever opened (Shift+Return routing, Tab-tag
    /// compose). Same pre-send pane guard, one-flight-per-agent tracking, and row spinner/"Message
    /// sent" label as `pressSend()` — `finishSend` already treats "no card open for this agent" as
    /// the normal case (every outcome reaches `onNotice` instead of a card). A confirmed `.sent`
    /// also calls `onSentDirect`, so the row can hold on to what it received. False when the row
    /// cannot take a message right now (same eligibility as `open(_:)`, but never opens anything).
    ///
    /// Always sent `confirmed: true`: unlike the card, there is no UI here to show a "the agent is
    /// mid-turn, send anyway?" prompt and wait for a second press, so a busy agent must just queue
    /// on the first attempt rather than dead-end with "not sent, open Message again." The pre-send
    /// pane guard above (open question/permission box) still applies regardless of `confirmed`.
    @discardableResult
    func sendDirect(to agent: AgentSnapshot, text: String) -> Bool {
        guard RowButtons.usableButtons(for: agent).contains(.message),
              let statusSource, let route = MessageRoute(agent: agent), let rowId = agent.rowId,
              !inFlight.contains(agent.id)
        else { return false }
        inFlight.insert(agent.id)
        objectWillChange.send()
        let request = Request(agentID: agent.id, label: agent.label, route: route, rowId: rowId, text: text, confirmed: true, notesOnSend: true)
        let epoch = epoch
        Task { [weak self] in
            let outcome = await Self.deliver(request, via: statusSource)
            self?.finishSend(outcome, of: request, epoch: epoch)
        }
        return true
    }

    // MARK: - Sending

    private struct Request: Sendable {
        let agentID: String
        let label: String
        let route: MessageRoute
        let rowId: String
        let text: String
        let confirmed: Bool
        /// True only for a `sendDirect` request: on `.sent`, `finishSend` calls `onSentDirect`.
        let notesOnSend: Bool
    }

    /// Reads the pane first: typed text would answer a question picker or a permission box. An inbox
    /// route has no pane to read (the dashboard refuses while the session shows a prompt) and never
    /// carries a slash command (e.g. Park's `/compact`): that fails here, nothing is sent.
    private static func deliver(_ request: Request, via source: any AgentStatusSource) async -> MessageSendOutcome {
        let paneId: String
        switch request.route {
        case .inbox:
            if MessageDraftValidator.check(request.text, allowsQuickCommands: false) == .slashCommand {
                return .failed(MessageRoute.inboxSlashCommandHint)
            }
            return await source.sendMessage(rowId: request.rowId, text: request.text, confirmed: request.confirmed)
        case .pane(let id):
            paneId = id
        case .toolPane(let id, _):
            if MessageDraftValidator.check(request.text, allowsQuickCommands: false, refusesShellPrefix: true) == .slashCommand {
                return .failed(MessageRoute.toolPaneCommandHint)
            }
            paneId = id
        }
        switch await source.paneScreen(paneId: paneId) {
        case .failure(let reason):
            return .failed("Couldn't check the terminal first (\(reason)). Nothing was sent.")
        case .screen(let lines, _):
            // A picker with an option already ticked is not one the panel can answer (`question` is nil for it), but
            // typed text would still land in it: the guard asks whether any picker is open.
            if PaneQuestionReader.identity(in: lines) != nil || PanePermissionReader.prompt(in: lines) != nil {
                return .failed(MessageCard.waitingOnYouText)
            }
        }
        return await source.sendMessage(rowId: request.rowId, text: request.text, confirmed: request.confirmed)
    }

    private func finishSend(_ outcome: MessageSendOutcome, of request: Request, epoch: Int) {
        guard epoch == self.epoch else { return }
        inFlight.remove(request.agentID)
        var showing = card?.agentID == request.agentID ? card : nil
        switch outcome {
        case .sent(let queued):
            sentLabels[request.agentID] = (queued ? "Message queued" : "Message sent", now().addingTimeInterval(sentLabelSeconds))
            scheduleRefresh(after: sentLabelSeconds)
            if request.notesOnSend { onSentDirect(request.agentID, request.text) }
            if showing != nil { close() }
            showing = nil
        case .needsConfirmation:
            showing?.stopSendingNeedingConfirmation()
            if showing == nil, !request.notesOnSend {
                onNotice("Message to \(request.label) not sent: the agent is mid-turn. Open Message again to queue it.")
            }
        case .failed(let reason):
            showing?.stopSending(error: reason)
            if showing == nil, !request.notesOnSend {
                onNotice("Message to \(request.label) not sent: \(reason)")
            }
        case .uncertain(let reason):
            showing?.stopSendingUncertain(reason)
            if showing == nil, !request.notesOnSend {
                onNotice("Message to \(request.label): \(reason)")
            }
        }
        // Headless sends report every outcome to the caller instead — it owns the retry policy
        // (see `onDirectSendOutcome`'s doc comment) and, unlike a card send, there is never a
        // `showing` card here for it to fall back to notifying through.
        if request.notesOnSend {
            onDirectSendOutcome(request.agentID, request.label, request.text, outcome)
        }
        if let showing { card = showing }
        objectWillChange.send()
    }

    /// Redraws once the row's "Message sent" has run its time.
    private func scheduleRefresh(after seconds: TimeInterval) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds + 0.1))
            self?.objectWillChange.send()
        }
    }

    // MARK: - Rows

    /// What the row says in place of its buttons while its message is on its way.
    func sendingLabel(for agent: AgentSnapshot) -> String? {
        inFlight.contains(agent.id) ? Self.sendingLabel : nil
    }

    /// What the row says for a few seconds after its message went: "Message sent" or "Message queued".
    func sentLabel(for agent: AgentSnapshot) -> String? {
        guard let note = sentLabels[agent.id], now() < note.until else { return nil }
        return note.text
    }

    // MARK: - Following the dashboard

    /// Every status update: closes the card when its agent has gone or ended. A blocked agent
    /// keeps the card (the dashboard's view flaps); the pane read before each send decides.
    func reconcile(with agents: [AgentSnapshot]) {
        guard let card else { return }
        if let agent = agents.first(where: { $0.id == card.agentID }), agent.section != .ended, agent.canFocus { return }
        close()
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
