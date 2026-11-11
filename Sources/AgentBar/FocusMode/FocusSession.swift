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

    let model: AgentPanelModel
    @Published private(set) var queue = FocusQueue()
    @Published private(set) var phase: Phase = .showing
    @Published private(set) var contexts: [String: FocusContext] = [:]
    /// Bumped by an inert ⌘← / ⌘→ (at either end): the view nudges the card.
    @Published private(set) var bumps = 0
    private(set) var agentsByID: [String: AgentSnapshot] = [:]

    var onExit: () -> Void = {}
    var onOpenTerminal: (AgentSnapshot) -> Void = { _ in }

    private let loadContext: @Sendable (String) async -> FocusContext
    private var openedForID: String?
    private var subscriptions: Set<AnyCancellable> = []
    private var timer: Task<Void, Never>?

    init(
        model: AgentPanelModel,
        loadContext: @escaping @Sendable (String) async -> FocusContext = FocusSession.readContext
    ) {
        self.model = model
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

    func openTerminal() {
        guard let agent = currentAgent else { return }
        onOpenTerminal(agent)
    }

    func park() {
        guard let agent = currentAgent else { return }
        _ = model.press(.park, on: agent.id)
    }

    func end() {
        timer?.cancel()
        subscriptions.removeAll()
        closeCards()
    }

    // MARK: - Following the feed and the cards

    func reconcile() {
        let candidates = model.focusCandidates()
        agentsByID = Dictionary(candidates.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        queue.update(listOrder: candidates.map(\.id))
        if phase == .sent { return }   // the timer moves on
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
}
