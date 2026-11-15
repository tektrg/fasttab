import Foundation
import Combine

/// What Focus mode knows about one agent from this Mac's transcript (the dashboard feed only has a
/// squeezed one-liner). `hasTranscript == false`: an agent on the other Mac / not Claude.
struct FocusContext: Equatable, Sendable {
    let lastMessage: String?
    let hasTranscript: Bool
}

/// One Focus mode visit: the queue, which card is up, "Sent ✓" and "All clear". Drives the SHARED
/// `AgentPanelModel` cards (`openCardForCorner` / `message.open`) exactly like the corner card does,
/// so every send path (answer, form batch, permission, plan, message) is the existing one.
@MainActor
final class FocusSession: ObservableObject {
    enum Phase: Equatable {
        case showing
        /// The answer just went: a short "Sent ✓", then the next agent.
        case sent
        /// Nothing left; Focus mode closes itself shortly.
        case allClear
    }

    /// What the right panel holds for the current agent.
    enum Ask: Equatable {
        case answer
        case permission
        case message
        /// The dashboard has not read the options yet.
        case loading
        /// Nothing AgentBar can answer from here (unparsed box, odd picker, no message route).
        case terminalOnly(String)
    }

    static let sentDisplaySeconds: TimeInterval = 0.7
    static let allClearSeconds: TimeInterval = 2
    /// A pause (after Go to agent) older than this is dropped: the next open starts fresh.
    static let pauseExpirySeconds: TimeInterval = 10 * 60
    static let toastSeconds: TimeInterval = 2.5
    static let answeredElsewhereToast = "Answered elsewhere"

    let model: AgentPanelModel
    @Published private(set) var queue = FocusQueue()
    @Published private(set) var phase: Phase = .showing
    @Published private(set) var contexts: [String: FocusContext] = [:]
    /// Bumped by an inert ⌘← / ⌘→ (at either end): the view nudges the card.
    @Published private(set) var bumps = 0
    private(set) var agentsByID: [String: AgentSnapshot] = [:]
    /// The keyboard highlight in a multi-question form (`FocusFormCursor`); Focus-only, the panel's form is mouse-only.
    @Published private(set) var formCursor: FocusFormCursor?

    /// Paused by Go to agent: the overlay is hidden, the queue keeps following the feed, the open card
    /// (and what is typed in it) stays; `resume()` brings the overlay back on the same agent, or the next.
    @Published private(set) var isPaused = false
    private(set) var pausedAt: Date?
    /// A quiet one-liner over the card ("Answered elsewhere", a disabled Go to's reason); clears itself.
    @Published private(set) var toast: String?

    var onExit: () -> Void = {}
    /// Go to agent: hide the overlay (the session stays, paused).
    var onPause: () -> Void = {}
    /// The jump: the list's Return path (`AgentSwitchCoordinator.switchTo`, failures not surfaced in
    /// the panel). A failure brings the overlay back with the switch coordinator's text.
    var onGoTo: (AgentSnapshot) async -> AgentSwitchCoordinator.Outcome = { _ in .switched }
    var onGoToFailed: () -> Void = {}

    private let loadContext: @Sendable (String) async -> FocusContext
    private var openedForID: String?
    private var subscriptions: Set<AnyCancellable> = []
    private var timer: Task<Void, Never>?
    private var toastTimer: Task<Void, Never>?
    private let now: () -> Date

    init(
        model: AgentPanelModel,
        loadContext: @escaping @Sendable (String) async -> FocusContext = FocusSession.readContext,
        now: @escaping () -> Date = Date.init
    ) {
        self.model = model
        self.now = now
        self.loadContext = loadContext
        let initial = model.focusCandidates()
        agentsByID = Dictionary(initial.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        queue = FocusQueue(listOrder: initial.map(\.id))
        let changes: [AnyPublisher<Void, Never>] = [
            model.$snapshot.map { _ in () }.eraseToAnyPublisher(),
            model.answer.$card.map { _ in () }.eraseToAnyPublisher(),
            model.permission.$card.map { _ in () }.eraseToAnyPublisher(),
            model.message.$card.map { _ in () }.eraseToAnyPublisher(),
        ]
        // @Published fires before the value is stored: reconcile on the next turn of the run loop.
        Publishers.MergeMany(changes)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.reconcile() }
            .store(in: &subscriptions)
        reconcile()
    }

    nonisolated static func readContext(sessionId: String) async -> FocusContext {
        await Task.detached(priority: .userInitiated) {
            let reader = SessionTranscriptReader.standard
            guard reader.transcriptURL(forSession: sessionId) != nil else {
                return FocusContext(lastMessage: nil, hasTranscript: false)
            }
            return FocusContext(lastMessage: reader.context(forSession: sessionId).latestMessage, hasTranscript: true)
        }.value
    }

    var currentAgent: AgentSnapshot? { queue.currentID.flatMap { agentsByID[$0] } }

    var ask: Ask {
        guard let agent = currentAgent else { return .terminalOnly("") }
        if model.answer.card?.agentID == agent.id { return .answer }
        if model.permission.card?.agentID == agent.id { return .permission }
        if model.message.card?.agentID == agent.id { return .message }
        switch agent.blockedOnYou {
        case .questionLoading?: return .loading
        case .questionNotAnswerable?: return .terminalOnly("This question can only be answered in the terminal.")
        case .permission?: return .terminalOnly("This prompt can't be read in full from here. Open the terminal to answer it.")
        case .question?, .permissionReview?: return .loading
        case nil: return .terminalOnly(agent.messageRefusal ?? "This agent can't take a message from here.")
        }
    }

    // MARK: - Navigation

    func moveForward() { move { $0.moveForward() } }
    func moveBack() { move { $0.moveBack() } }

    private func move(_ step: (inout FocusQueue) -> Bool) {
        guard phase == .showing, step(&queue) else { bumps += 1; return }
        closeCards()
        openedForID = nil
        reconcile()
    }

    /// The current agent's home, for the Go to button; nil when no agent is up.
    var destination: FocusDestination? { currentAgent.map(FocusDestination.init(agent:)) }

    /// ⌘↩ / the Go to button: pause Focus mode and switch to the agent's home. A home that cannot be
    /// reached is said (toast + bump), never a silent no-op; a failed switch resumes with the red notice.
    func goToAgent() {
        guard phase == .showing, !isPaused, let agent = currentAgent else { return }
        let destination = FocusDestination(agent: agent)
        guard destination.isEnabled else {
            bumps += 1
            showToast(destination.reason ?? FocusDestination.noHomeReason)
            return
        }
        pause()
        onPause()
        Task { [weak self] in
            guard let self else { return }
            if case .failed(let message) = await self.onGoTo(agent) {
                self.model.reportSwitchFailure(message)
                self.resume()
                self.onGoToFailed()
            }
        }
    }

    func pause() {
        isPaused = true
        pausedAt = now()
        timer?.cancel()
        if phase == .sent { phase = .showing }
    }

    func resume() {
        guard isPaused else { return }
        isPaused = false
        pausedAt = nil
        reconcile()
    }

    func isPauseExpired(at date: Date) -> Bool {
        guard isPaused, let pausedAt else { return false }
        return date.timeIntervalSince(pausedAt) >= Self.pauseExpirySeconds
    }

    private func showToast(_ text: String) {
        toast = text
        toastTimer?.cancel()
        toastTimer = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.toastSeconds))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    func park() {
        guard let agent = currentAgent else { return }
        _ = model.press(.park, on: agent.id)
    }

    func end() {
        timer?.cancel()
        toastTimer?.cancel()
        subscriptions.removeAll()
        closeCards()
    }

    // MARK: - Following the feed and the cards

    func reconcile() {
        // A dead (or not-yet-arrived) feed shows no agents; that is not "they all went away":
        // keep the queue, the card and the position until the feed is back (no false All clear).
        guard model.isStatusFeedLive || queue.isAllClear else { return }
        let candidates = model.focusCandidates()
        let shownAgent = queue.currentID.flatMap { agentsByID[$0] }
        agentsByID = Dictionary(candidates.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        queue.update(listOrder: candidates.map(\.id))
        if isPaused { return }   // only the queue follows the feed; resume() reopens
        if phase == .sent { return }   // the timer moves on
        if phase == .showing, let shownAgent, agentsByID[shownAgent.id] == nil, !queue.isAllClear,
           model.sendingLabel(for: shownAgent) == nil {
            showToast(Self.answeredElsewhereToast)
        }
        if let id = openedForID, id == queue.currentID, !isCardOpen(for: id),
           let agent = agentsByID[id], model.sendingLabel(for: agent) != nil {
            showSent(for: id)
            return
        }
        if queue.isAllClear {
            guard phase != .allClear else { return }
            closeCards()
            openedForID = nil
            phase = .allClear
            schedule(after: Self.allClearSeconds) { [weak self] in self?.onExit() }
            return
        }
        if phase == .allClear { timer?.cancel() }
        phase = .showing
        openCurrentIfNeeded()
    }

    private func showSent(for id: String) {
        phase = .sent
        schedule(after: Self.sentDisplaySeconds) { [weak self] in
            guard let self else { return }
            self.queue.markHandled(id)
            self.openedForID = nil
            self.phase = .showing
            self.reconcile()
        }
    }

    private func openCurrentIfNeeded() {
        guard let agent = currentAgent else { return }
        loadContextIfNeeded(agent)
        if isCardOpen(for: agent.id) { openedForID = agent.id; return }
        if openedForID != nil, openedForID != agent.id { closeCards() }
        if model.openCardForCorner(agentID: agent.id) {
            openedForID = agent.id
        } else if agent.blockedOnYou == nil {
            model.answer.close()
            model.permission.close()
            if model.message.open(agent) { openedForID = agent.id }
        }
    }

    private func loadContextIfNeeded(_ agent: AgentSnapshot) {
        guard contexts[agent.id] == nil else { return }
        guard let sessionId = agent.sessionId else {
            contexts[agent.id] = FocusContext(lastMessage: nil, hasTranscript: false)
            return
        }
        let load = loadContext
        Task { [weak self] in
            let context = await load(sessionId)
            self?.contexts[agent.id] = context
        }
    }

    private func isCardOpen(for id: String) -> Bool {
        model.answer.card?.agentID == id || model.permission.card?.agentID == id || model.message.card?.agentID == id
    }

    private func closeCards() {
        model.answer.close()
        model.permission.close()
        model.message.close()
    }

    private func schedule(after seconds: TimeInterval, _ action: @escaping @MainActor () -> Void) {
        timer?.cancel()
        timer = Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            action()
        }
    }

    // MARK: - Form keys

    /// The open answer card's form, when it is one.
    var openForm: AnswerFormState? { model.answer.card?.form }

    /// The highlight for the open form (top of the form until a key moves it).
    func cursor(for form: AnswerFormState) -> FocusFormCursor { FocusFormCursor.current(formCursor, for: form) }

    /// A Focus key while a form card is up. False when no form is open (the caller handles the key).
    @discardableResult
    func handleFormKey(_ action: FocusKey.Action) -> Bool {
        guard let form = openForm else { return false }
        var cursor = cursor(for: form)
        let effect: FocusFormCursor.Effect
        switch action {
        case .move(let step):
            cursor.move(by: step, in: form)
            effect = .none
        case .pick(let number):
            effect = cursor.pick(number, in: form)
        case .space:
            effect = cursor.space(in: form)
        case .enter:
            effect = cursor.enter(in: form)
            if effect == .none { cursor.advanceAfterChoice(in: form) }
        default:
            return false
        }
        switch effect {
        case .none:
            break
        case .click(let row, let question):
            model.answer.clickFormRow(row, of: question)
            if let updated = openForm, action != .space { cursor.advanceAfterChoice(in: updated) }
        case .submit:
            model.answer.handle(.enter)
        }
        formCursor = cursor
        return true
    }

    /// A mouse click on a form row: the highlight follows it, then the card's model takes the click.
    func clickForm(row: Int, of question: Int) {
        guard let form = openForm else { return }
        var cursor = cursor(for: form)
        cursor.question = question
        cursor.row = row
        formCursor = cursor
        model.answer.clickFormRow(row, of: question)
    }
}
