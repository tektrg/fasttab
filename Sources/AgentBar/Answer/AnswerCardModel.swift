import AppKit
import Foundation

/// Observable state behind the answer card: opens it on a blocked agent's
/// question, feeds it keys, sends the answer the user chose, and keeps the card
/// in step with what the dashboard reports. The rules for keys live in the pure
/// `AnswerCardState`; the transcript reading is behind `loadSessionContext`.
///
/// Safety rules: an answer is sent only from a key/click that means "send",
/// once per decision (a refusal is shown, never retried), and always with the
/// question the user was looking at, so the dashboard refuses if the pane moved on.
@MainActor
final class AnswerCardModel: ObservableObject {
    static let alreadyAnsweredMessage = "Already answered. Waiting for the dashboard to catch up."
    static let noReplyMessage = "No reply from the dashboard to your answer yet. Check the agent's terminal: it may have gone through."
    static let noSourceMessage = "No status dashboard to send the answer to."

    typealias SessionContextLoad = @Sendable (_ sessionId: String) async -> SessionContext
    /// The AskUserQuestion form the agent is waiting on, per its transcript (nil: none, or unreadable).
    typealias PendingFormLoad = @Sendable (_ sessionId: String) async -> PendingQuestionForm?
    /// What the transcript recorded for a submitted form (nil: nothing yet, or unreadable).
    typealias RecordedAnswersLoad = @Sendable (_ sessionId: String, _ form: PendingQuestionForm) async -> RecordedFormAnswers?

    /// Written only by this model (its own files: `AnswerCardModel+Form`); everything else reads it.
    @Published var card: AnswerCard?

    /// Where answers go; set by the host, replaced with the dashboard address.
    var statusSource: (any AgentStatusSource)?
    /// A sentence for the panel's footer (an answer that never reached the pane).
    var onNotice: (String) -> Void = { _ in }
    /// The question was answered and nothing follows it: the host moves on.
    var onAnswered: (_ agentID: String) -> Void = { _ in }
    /// Esc pressed inside the card's text field: the host may use it to close a failure notice first
    /// (true = used up, the card stays as it is).
    var consumeEscape: () -> Bool = { false }
    /// The card's text field lost the keyboard: the host gives it back to the search field.
    var onReleaseKeyboard: () -> Void = {}

    private let loadSessionContext: SessionContextLoad
    let loadPendingForm: PendingFormLoad
    let loadRecordedAnswers: RecordedAnswersLoad
    private let openFile: (URL) -> Void
    private let contextLoader = LatestResultLoader<SessionContext>()
    let formLoader = LatestResultLoader<PendingQuestionForm?>()
    /// The batch sends of multi-question forms, one per agent, and each one's total-time watchdog (see `AnswerCardModel+Form`).
    var batchTasks: [String: Task<Void, Never>] = [:]
    var batchWatchdogs: [String: Task<Void, Never>] = [:]
    let formTiming: FormBatchTiming
    /// Answers on their way, and the questions just answered. The dashboard's view lags
    /// the pane by up to ~15s, so until it shows something else an answered question is not open.
    var tracker = AnswerSendTracker()
    let now: () -> Date
    private let sendExpirySeconds: TimeInterval

    init(
        now: @escaping () -> Date = Date.init,
        sendExpirySeconds: TimeInterval = AnswerSendTracker.expirySeconds,
        loadSessionContext: @escaping SessionContextLoad = AnswerCardModel.readTranscript,
        loadPendingForm: @escaping PendingFormLoad = AnswerCardModel.readPendingForm,
        loadRecordedAnswers: @escaping RecordedAnswersLoad = AnswerCardModel.readRecordedAnswers,
        formTiming: FormBatchTiming = FormBatchTiming(),
        openFile: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }
    ) {
        self.now = now
        self.sendExpirySeconds = sendExpirySeconds
        self.loadSessionContext = loadSessionContext
        self.loadPendingForm = loadPendingForm
        self.loadRecordedAnswers = loadRecordedAnswers
        self.formTiming = formTiming
        self.openFile = openFile
    }

    /// Reads off the main thread: the transcript can be 100MB+ (only its tail is read).
    nonisolated static func readTranscript(sessionId: String) async -> SessionContext {
        await Task.detached(priority: .userInitiated) {
            SessionTranscriptReader.standard.context(forSession: sessionId)
        }.value
    }

    /// Reads off the main thread, like `readTranscript`.
    nonisolated static func readPendingForm(sessionId: String) async -> PendingQuestionForm? {
        await Task.detached(priority: .userInitiated) {
            SessionTranscriptReader.standard.pendingQuestionForm(forSession: sessionId)
        }.value
    }

    /// Reads off the main thread, like `readTranscript`.
    nonisolated static func readRecordedAnswers(sessionId: String, form: PendingQuestionForm) async -> RecordedFormAnswers? {
        await Task.detached(priority: .userInitiated) {
            SessionTranscriptReader.standard.recordedAnswers(forSession: sessionId, form: form)
        }.value
    }

    var isOpen: Bool { card != nil }

    // MARK: - Opening and closing

    /// Opens the card on `agent`'s question. Returns false (with a reason for the
    /// footer) when it cannot be answered from here.
    @discardableResult
    func open(_ agent: AgentSnapshot) -> Bool {
        // A hook request (status-only session or herdr pane) is answered by id; anything else needs its pane.
        let paneId = agent.paneId ?? ""
        guard case .question? = agent.blockedOnYou, agent.hookRequest != nil || !paneId.isEmpty else {
            return false
        }
        guard statusSource != nil else {
            onNotice(Self.noSourceMessage)
            return false
        }
        guard !isAwaiting(agent) else { return false }
        guard let question = questionToOpen(for: agent) else {
            onNotice(Self.alreadyAnsweredMessage)
            return false
        }
        close()
        // A hook request is answered by id only: the card never keeps a pane to read or type into.
        var opened = AnswerCard(agent: agent, paneId: agent.hookRequest == nil ? paneId : "", question: question)
        if let draft = tracker.takeDraft(agentID: agent.id, for: question.identity) { opened.state.restore(draft) }
        opened.form = Self.hookForm(agent.hookRequest)
        card = opened
        loadContext()
        // A hook request carries all its questions itself: no transcript read for the form.
        if agent.hookRequest == nil { loadPendingFormForCard() }
        return true
    }

    func close() {
        contextLoader.cancel()
        formLoader.cancel()
        card = nil
    }

    /// Forgets everything about the old dashboard's agents.
    func reset() {
        cancelBatch()
        close()
        tracker.reset()
    }

    // MARK: - Keys and clicks

    func handle(_ key: AnswerCardState.Key) {
        guard var card else { return }
        if key == .escape, consumeEscape() { return }
        if card.form != nil {
            handleFormKey(key)
            return
        }
        let wasTyping = card.state.phase == .typingOther
        let effect = card.state.handle(key)
        self.card = card
        apply(effect)
        releaseKeyboardIfLeftTyping(wasTyping)
    }

    func clickOption(at position: Int) {
        guard var card else { return }
        let wasTyping = card.state.phase == .typingOther
        card.state.clickOption(at: position)
        self.card = card
        releaseKeyboardIfLeftTyping(wasTyping)
    }

    /// The Send / Submit button.
    func pressSend() {
        handle(.send)
    }

    func setOtherText(_ text: String) {
        card?.state.otherText = text
    }

    func openPlan() {
        guard let url = card?.planFile else { return }
        openFile(url)
    }

    private func apply(_ effect: AnswerCardState.Effect) {
        switch effect {
        case .none: break
        case .close: close()
        case .send(let choice): send(choice)
        }
    }

    private func releaseKeyboardIfLeftTyping(_ wasTyping: Bool) {
        if wasTyping, card?.state.phase != .typingOther { onReleaseKeyboard() }
    }

    // MARK: - Sending

    /// The Send press: the card closes at once and the answer goes out in the
    /// background; the row shows "Sending answer…" until it is settled.
    private func send(_ choice: AnswerChoice) {
        guard let card, let statusSource else { return }
        let identity = card.state.question.identity
        let agentID = card.agentID
        let paneId = card.paneId
        let draft = card.state.draft
        guard let token = tracker.begin(agentID: agentID, at: now()) else { return }
        close()
        scheduleExpiry(agentID: agentID, token: token)
        if let hookRequest = card.hookRequest {
            let shown = card.state.question
            Task { [weak self] in
                let result = await Self.sendHookAnswer(choice, to: shown, of: hookRequest, source: statusSource)
                self?.finishSend(result, token: token, agentID: agentID, identity: identity, draft: draft)
            }
            return
        }
        Task { [weak self] in
            // Reading the pane first (read-only) so the question is sent as the dashboard
            // itself reads it; nothing is typed into the pane by this step.
            let toSend = await Self.identityToSend(shown: identity, paneId: paneId, source: statusSource)
            let result = await statusSource.answer(paneId: paneId, choice: choice, question: toSend)
            self?.finishSend(result, token: token, agentID: agentID, identity: identity, draft: draft)
        }
    }

    /// The question exactly as the pane reads now, when it is the one shown. The status feed's
    /// copy can differ from it in wrapping, and the dashboard refuses an answer unless the two
    /// match letter for letter (a "question is gone" refusal about a question that is still there).
    nonisolated private static func identityToSend(
        shown: QuestionIdentity, paneId: String, source: any AgentStatusSource
    ) async -> QuestionIdentity {
        guard case .screen(let lines, _) = await source.paneScreen(paneId: paneId) else { return shown }
        return shown.resolved(against: PaneQuestionReader.identity(in: lines))
    }

    func finishSend(_ result: AnswerResult, token: Int, agentID: String, identity: QuestionIdentity, draft: AnswerDraft) {
        switch result {
        case .failed(let message):
            guard tracker.failed(agentID: agentID, token: token, draft: draft) else { return }
            onNotice("Answer not sent: \(message)")
        case .sent(let next):
            guard tracker.succeeded(agentID: agentID, token: token, identity: identity, next: next, at: now()) else { return }
            scheduleRefresh(after: AnswerSendTracker.expirySeconds)
            if next == nil { onAnswered(agentID) }
        }
        objectWillChange.send()
    }

    /// A send with no reply in time frees its row and says so; the answer may still have gone through.
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

    /// The row shows "Sending answer…" instead of its buttons.
    func isAwaiting(_ agent: AgentSnapshot) -> Bool {
        var shown: QuestionIdentity?
        if case .question(let question)? = agent.blockedOnYou { shown = question.identity }
        return tracker.isAwaiting(agentID: agent.id, showing: shown, now: now())
    }

    /// The question the card should open on: the dashboard's, or the next one of a form just answered.
    private func questionToOpen(for agent: AgentSnapshot) -> AnswerableQuestion? {
        guard case .question(let shown)? = agent.blockedOnYou else { return nil }
        guard tracker.hasAnswered(agentID: agent.id, shown.identity) else { return shown }
        return tracker.nextQuestion(agentID: agent.id, after: shown.identity)
    }

    // MARK: - Following the dashboard

    /// Every status update: keeps the card on what the pane actually asks. The
    /// dashboard's copy can be ~15s behind, so a question we just answered is
    /// not taken as the current one; a different question replaces the card's
    /// (never carrying the old choice over); a question that is gone closes it.
    func reconcile(with agents: [AgentSnapshot]) {
        var current: [String: QuestionIdentity] = [:]
        for agent in agents {
            if case .question(let question)? = agent.blockedOnYou { current[agent.id] = question.identity }
        }
        tracker.settle(currentQuestions: current)
        guard let card else { return }
        // A form being sent, or stopped with its report, is not the dashboard's to move or close.
        guard card.form?.isEditable ?? true else { return }
        let agent = agents.first { $0.id == card.agentID }
        // Another hook request (or none) is a different prompt, whatever its wording: the card was for that one.
        guard card.hookRequest?.requestId == agent?.hookRequest?.requestId else {
            close()
            return
        }
        switch agent?.blockedOnYou {
        case .question(let question)?:
            follow(question, in: card)
        case .questionLoading?, .questionNotAnswerable?:
            return   // the dashboard's view is between readings: the card stays on the question it has
        case .permission?, .permissionReview?, nil:
            close()
        }
    }

    private func follow(_ current: AnswerableQuestion, in shownCard: AnswerCard) {
        var card = shownCard
        if let form = card.form?.form {
            // Another tab of the same form: the card already shows it. Anything else: an ordinary card on it.
            if form.indexOfQuestion(matching: current.question) != nil { return }
            card.form = nil
        }
        guard current != card.state.question, !tracker.hasAnswered(agentID: card.agentID, current.identity) else { return }
        var replaced = card
        let questionChanged = current.identity != card.state.question.identity
        replaced.state = card.state.replacing(question: current)
        if questionChanged { replaced.sessionContext = replaced.sessionId == nil ? .empty : nil }
        self.card = replaced
        if questionChanged { loadContext() }
    }

    // MARK: - Transcript

    func loadContext() {
        guard let sessionId = card?.sessionId, let agentID = card?.agentID else { return }
        let load = loadSessionContext
        contextLoader.load({ await load(sessionId) }) { [weak self] context in
            guard self?.card?.agentID == agentID else { return }
            self?.card?.sessionContext = context
        }
    }
}
