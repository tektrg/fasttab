import Foundation
import Combine
import CommandBarKit

/// Observable state behind the panel: the latest snapshot, the search text,
/// the selection, the user's frecency and parked agents, and the row buttons
/// (Done / Park / Close pane), the pane peek and the answer card (`answer`).
/// All derivation lives in the pure `AgentListBuilder` / `AgentSelection` /
/// `FrecencyStore` / `TriageState` / `RowActionMachine`.
@MainActor
final class AgentPanelModel: ObservableObject {
    @Published private(set) var snapshot: StatusSnapshot?
    @Published private(set) var presentation: AgentListPresentation = .connecting
    /// Moving the selection drops any keyboard-highlighted button.
    @Published private(set) var selectedAgentID: String? {
        didSet { if selectedAgentID != oldValue { highlightedButton = nil } }
    }
    /// The selected row's button the keyboard is on (←/→), if any; ↩ presses it.
    @Published private(set) var highlightedButton: RowButton?
    /// Where each row's Done / Close pane press has got to (see `RowActionState`).
    @Published private(set) var rowActionStates: [String: RowActionState] = [:]
    /// Bumped on every show so the search field re-grabs keyboard focus.
    @Published private(set) var focusRequest = 0
    /// Typing re-filters and always jumps back to the first row.
    @Published var query = "" {
        didSet {
            guard query != oldValue else { return }
            rebuild()
            selectedAgentID = presentation.selectableAgentIDs.first
            closePeek()
        }
    }

    /// The pane-screen peek (Space), or nil while the list shows.
    @Published private(set) var peek: PanePeek?

    /// Where a peek reads the pane screen from; set by the host, and replaced
    /// when the user points AgentBar at another dashboard.
    var statusSource: (any AgentStatusSource)? {
        didSet {
            answer.statusSource = statusSource
            permission.statusSource = statusSource
        }
    }

    /// Answering a blocked agent's question (replaces the list while open). Its
    /// changes republish through this model, so views need observe only this.
    let answer: AnswerCardModel

    /// Approving or denying a blocked agent's permission box (replaces the list while open).
    /// Same republishing as `answer`.
    let permission: PermissionCardModel

    /// A card (answer or permission) is showing in place of the list.
    var isCardOpen: Bool { answer.isOpen || permission.isOpen }

    /// Strip at the bottom of the panel: a failed switch or row action, else a shortcut problem.
    @Published private(set) var footerNotice: PanelFooterNotice?

    /// What the user chose to show (Settings > List); changes apply at once.
    @Published private(set) var listSettings: AgentListSettings

    /// Where the status feed is expected, for the "feed down" message.
    @Published private(set) var dashboardAddress: String

    /// Called when the user activates a row (Enter, click, or release after
    /// cycling). The host closes the panel and switches to the agent; frecency
    /// is recorded later, by `recordSwitch`, once the switch worked.
    var onActivate: (AgentSnapshot) -> Void = { _ in }

    /// Called when an agent enters Needs you (see `NeedsYouArrivalDetector`);
    /// the host shows the corner tab.
    var onNeedsYouArrival: (CornerTabContent) -> Void = { _ in }

    private let store: FrecencyStore
    private let triageStore: TriageStore
    private let now: () -> Date
    private let switchErrorSeconds: TimeInterval
    private let completedHoldSeconds: TimeInterval
    private var frecency: [String: FrecencyEntry]
    private var triage: TriageState
    private var transientNotice: PanelFooterNotice?
    private var hotkeyIssue: String?
    private var switchErrorClearTask: Task<Void, Never>?
    private let peekLoader = LatestResultLoader<PaneScreenResult>()
    private var arrivalDetector = NeedsYouArrivalDetector()
    private var blockerMemory = BlockerMemory()
    private var lastAnswerNotice: (sentence: String, at: Date)?
    private var answerObservation: AnyCancellable?
    private var permissionObservation: AnyCancellable?

    init(
        store: FrecencyStore = FrecencyStore(),
        triageStore: TriageStore = TriageStore(),
        listSettings: AgentListSettings = .standard,
        dashboardAddress: String = DashboardEndpoint(baseURL: DashboardEndpoint.defaultBaseURL).displayAddress,
        switchErrorSeconds: TimeInterval = 6,
        completedHoldSeconds: TimeInterval = 8,
        answer: AnswerCardModel = AnswerCardModel(),
        permission: PermissionCardModel = PermissionCardModel(),
        now: @escaping () -> Date = { Date() }
    ) {
        self.answer = answer
        self.permission = permission
        self.store = store
        self.triageStore = triageStore
        self.triage = triageStore.load()
        self.completedHoldSeconds = completedHoldSeconds
        self.listSettings = listSettings
        self.dashboardAddress = dashboardAddress
        self.switchErrorSeconds = switchErrorSeconds
        self.now = now
        self.frecency = store.load(now: now())
        wireAnswerCard()
        wirePermissionCard()
    }

    private func wireAnswerCard() {
        answerObservation = answer.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        answer.onNotice = { [weak self] sentence in self?.showAnswerNotice(sentence) }
        answer.onAnswered = { [weak self] agentID in self?.advanceSelection(pastAnswered: agentID) }
        answer.onReleaseKeyboard = { [weak self] in self?.focusRequest += 1 }
    }

    private func wirePermissionCard() {
        permissionObservation = permission.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        permission.onNotice = { [weak self] sentence in self?.showAnswerNotice(sentence) }
        permission.onDecided = { [weak self] agentID in self?.advanceSelection(pastAnswered: agentID) }
        permission.onEndpointMissing = { [weak self] in self?.reapplyBlockerRules() }
        permission.onOpenTerminal = { [weak self] agentID in self?.activate(agentID: agentID) }
    }

    /// The blockers as the panel shows them: steadied against the dashboard's flapping, and
    /// with Review turned back into Open terminal while the dashboard cannot take approvals.
    private func shownBlockers(_ agents: [AgentSnapshot]) -> [AgentSnapshot] {
        permission.withoutReviewIfEndpointMissing(blockerMemory.steadied(agents, now: now()))
    }

    /// A row's rules changed under it (the dashboard turned out to lack /api/permission).
    private func reapplyBlockerRules() {
        guard let current = snapshot else { return }
        snapshot = current.replacingAgents(permission.withoutReviewIfEndpointMissing(current.agents))
        rebuild()
        selectedAgentID = AgentSelection.reconciled(selectedAgentID, in: presentation.selectableAgentIDs)
        settleRowActions()
    }

    func receive(_ received: StatusSnapshot) {
        let snapshot = received.replacingAgents(shownBlockers(received.agents))
        self.snapshot = snapshot
        // A dead feed shows no agents; that must not read as "they all went away".
        if !snapshot.health.isDown, triage.observe(snapshot.agents) { triageStore.save(triage) }
        rebuild()
        trackNeedsYou()
        selectedAgentID = AgentSelection.reconciled(selectedAgentID, in: presentation.selectableAgentIDs)
        settleRowActions()
        closePeekUnlessStillSelected()
        reconcileAnswerCard()
    }

    /// New list settings: re-derive the list, keeping the selection while it survives.
    func apply(_ settings: AgentListSettings) {
        guard settings != listSettings else { return }
        listSettings = settings
        rebuild()
        // A setting can reveal agents that were always waiting: not arrivals.
        trackNeedsYou(reportingArrivals: false)
        selectedAgentID = AgentSelection.reconciled(selectedAgentID, in: presentation.selectableAgentIDs)
        closePeekUnlessStillSelected()
        reconcileAnswerCard()
    }

    /// The status feed now comes from another dashboard: forget the old feed's
    /// agents and wait for the new one's first update.
    func useDashboard(address: String) {
        dashboardAddress = address
        snapshot = nil
        blockerMemory.reset()
        lastAnswerNotice = nil
        rowActionStates = [:]
        rebuild()
        trackNeedsYou()
        selectedAgentID = nil
        closePeek()
        answer.reset()
        permission.reset()
    }

    /// Fresh start for each summon: empty search, first row selected.
    func resetForShow() {
        clearTransientNotice()
        repostRecentAnswerNotice()
        closePeek()
        answer.close()
        permission.close()
        cancelConfirmations()
        query = ""
        rebuild()
        selectedAgentID = presentation.selectableAgentIDs.first
        focusRequest += 1
    }

    func moveSelection(by step: Int) {
        closePeek()
        answer.close()
        permission.close()
        selectedAgentID = AgentSelection.moved(from: selectedAgentID, by: step, in: presentation.selectableAgentIDs)
    }

    /// Hover: only rows that can be activated take the highlight.
    func select(agentID: String) {
        guard presentation.selectableAgentIDs.contains(agentID) else { return }
        selectedAgentID = agentID
        closePeekUnlessStillSelected()
    }

    /// ↑/↓ from the keyboard: moves the highlight inside an open answer card,
    /// else the selection in the list.
    func moveSelectionOrAnswerHighlight(by step: Int) {
        if answer.isOpen {
            answer.handle(step < 0 ? .up : .down)
        } else if permission.isOpen {
            permission.handle(step < 0 ? .up : .down)
        } else {
            moveSelection(by: step)
        }
    }

    /// Space. Ticks the highlighted option in an open answer card; otherwise
    /// peeks at the selected agent's screen, or closes the peek. Only
    /// with an empty search: otherwise it is a literal space in the query, and
    /// this returns false so the field types it.
    @discardableResult
    func togglePeek() -> Bool {
        if answer.isOpen {
            answer.handle(.space)
            return true
        }
        if permission.isOpen {
            permission.handle(.other)
            return true
        }
        guard query.isEmpty else { return false }
        if peek != nil {
            closePeek()
        } else {
            openPeekOnSelected()
        }
        return true
    }

    func closePeek() {
        peekLoader.cancel()
        peek = nil
    }

    private func openPeekOnSelected() {
        guard let selectedAgentID,
              let agent = presentation.agents.first(where: { $0.id == selectedAgentID })
        else { return }
        var opened = PanePeek(agentID: agent.id, label: agent.label, projectName: agent.projectName, content: .loading)
        guard let paneId = agent.paneId, !paneId.isEmpty else {
            opened.content = .unavailable(PanePeek.endedAgentMessage)
            peek = opened
            return
        }
        guard let statusSource else {
            opened.content = .unavailable(PanePeek.noSourceMessage)
            peek = opened
            return
        }
        peek = opened
        peekLoader.load({ await statusSource.paneScreen(paneId: paneId) }) { [weak self] result in
            self?.peek?.content = PanePeek.content(from: result)
        }
    }

    private func closePeekUnlessStillSelected() {
        if peek?.agentID != selectedAgentID { closePeek() }
    }

    /// Enter: presses the highlighted button, or with none highlighted switches to the agent.
    func activateSelected() {
        if answer.isOpen {
            answer.handle(.enter)
            return
        }
        if permission.isOpen {
            permission.handle(.enter)
            return
        }
        guard let selectedAgentID else { return }
        if let highlightedButton {
            press(highlightedButton, on: selectedAgentID)
        } else {
            activate(agentID: selectedAgentID)
        }
    }

    func activate(agentID: String) {
        guard presentation.selectableAgentIDs.contains(agentID),
              let agent = presentation.agents.first(where: { $0.id == agentID })
        else { return }
        onActivate(agent)
    }

    // MARK: - Row buttons (Done / Park / Unpark / Close pane)

    private var selectedAgent: AgentSnapshot? {
        selectedAgentID.flatMap { id in presentation.agents.first { $0.id == id } }
    }

    /// ←/→: moves the highlight across the selected row's buttons. Only with an
    /// empty search (otherwise the arrows move the text caret, and this returns
    /// false so the field handles them) - the same rule as Space-to-peek.
    /// While peeking the arrows do nothing. Left off the first button
    /// un-highlights it and cancels a pending confirmation.
    @discardableResult
    func moveButtonHighlight(by step: Int) -> Bool {
        guard query.isEmpty else { return false }
        if permission.isOpen {
            permission.handle(.other)   // a stray key never carries a pending "Allow always" over
            return true
        }
        guard !answer.isOpen else { return true }
        guard peek == nil, let agent = selectedAgent else { return true }
        let previous = highlightedButton
        highlightedButton = RowButtonHighlight.moved(from: previous, by: step, in: usableButtons(for: agent))
        if previous != nil, highlightedButton == nil { cancelConfirmation(for: agent.id) }
        return true
    }

    /// Esc: backs out of the button level (un-highlights, cancels a pending
    /// confirmation). False when there was nothing to back out of, so Esc
    /// goes on to close the peek / panel.
    func backOutOfButtons() -> Bool {
        if answer.isOpen {
            answer.handle(.escape)   // to the list; ignored while an answer is being sent
            return true
        }
        if permission.isOpen {
            permission.handle(.escape)   // cancels a pending "Allow always", else back to the list
            return true
        }
        guard let selectedAgentID else { return false }
        let confirming = isConfirming(selectedAgentID)
        guard highlightedButton != nil || confirming else { return false }
        highlightedButton = nil
        cancelConfirmation(for: selectedAgentID)
        return true
    }

    /// A press on `button` of agent `agentID` (mouse, or Enter on the highlight).
    /// Park / Unpark act at once; Done / Close pane ask the dashboard, and the
    /// returned task ends when it has answered (tests await it).
    @discardableResult
    func press(_ button: RowButton, on agentID: String) -> Task<Void, Never>? {
        guard let agent = presentation.agents.first(where: { $0.id == agentID }),
              usableButtons(for: agent).contains(button) else { return nil }
        switch RowActionMachine.plan(pressing: button, current: rowActionStates[agentID]) {
        case .ignore:
            return nil
        case .park:
            setParked(true, agentID: agentID)
            return nil
        case .unpark:
            setParked(false, agentID: agentID)
            return nil
        case .openAnswer:
            selectedAgentID = agentID
            closePeek()
            permission.close()
            answer.open(agent)
            return nil
        case .openReview:
            selectedAgentID = agentID
            closePeek()
            answer.close()
            permission.open(agent)
            return nil
        case .openTerminal:
            onActivate(agent)
            return nil
        case .send(let kind, let confirmed):
            return send(kind, confirmed: confirmed, button: button, agent: agent)
        }
    }

    private func setParked(_ isParked: Bool, agentID: String) {
        let following = AgentSelection.neighbour(of: agentID, in: presentation.selectableAgentIDs)
        rowActionStates[agentID] = nil
        if isParked { triage.park(agentID) } else { triage.unpark(agentID) }
        triageStore.save(triage)
        rebuild()
        trackNeedsYou()
        // A parked row leaves the top of the list: carry on with the next one.
        // An unparked one stays selected, wherever it lands.
        selectedAgentID = AgentSelection.reconciled(isParked ? following : agentID, in: presentation.selectableAgentIDs)
        highlightedButton = nil
    }

    private func send(_ kind: SessionActionKind, confirmed: Bool, button: RowButton, agent: AgentSnapshot) -> Task<Void, Never>? {
        guard let statusSource, let rowId = agent.rowId else {
            showTransientNotice(.actionFailed(RowActionText.failureNotice(kind: kind, message: PanePeek.noSourceMessage)))
            return nil
        }
        rowActionStates[agent.id] = .busy(button)
        return Task { [weak self] in
            let outcome = await statusSource.perform(kind, rowId: rowId, confirmed: confirmed)
            self?.finishPress(of: button, kind: kind, agentID: agent.id, outcome: outcome)
        }
    }

    private func finishPress(of button: RowButton, kind: SessionActionKind, agentID: String, outcome: SessionActionOutcome) {
        let result = RowActionMachine.state(after: outcome, pressing: button)
        rowActionStates[agentID] = result.state
        if let failure = result.failure {
            showTransientNotice(.actionFailed(RowActionText.failureNotice(kind: kind, message: failure)))
        }
        if case .completed = result.state {
            expireCompletedState(of: agentID, after: completedHoldSeconds)
            // Done: the agent is finished with, so carry on with the next row.
            if button == .done, selectedAgentID == agentID {
                let following = AgentSelection.neighbour(of: agentID, in: presentation.selectableAgentIDs)
                selectedAgentID = following ?? selectedAgentID
            }
        }
    }

    /// After an answered question: on to the next row that needs the user.
    private func advanceSelection(pastAnswered agentID: String) {
        let needsYouIDs = presentation.agents.filter { $0.section == .needsYou && $0.canFocus }.map(\.id)
        if let following = AgentSelection.neighbour(of: agentID, in: needsYouIDs) { selectedAgentID = following }
    }

    /// Keeps an open answer card true to the latest status (over every agent the
    /// user could see, not just the ones the search leaves).
    private func reconcileAnswerCard() {
        let shown = snapshot.map { AgentListBuilder.shownAgents(in: $0, settings: listSettings, triage: triage) } ?? []
        answer.reconcile(with: shown)
        permission.reconcile(with: shown)
    }

    /// A "completed" row waits for the next status update to show the result;
    /// if none does (a lagging feed), it stops waiting rather than stay stuck.
    private func expireCompletedState(of agentID: String, after seconds: TimeInterval) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard case .completed? = self?.rowActionStates[agentID] else { return }
            self?.rowActionStates[agentID] = nil
        }
    }

    /// After a refresh: forget states of rows that are gone, and completed ones
    /// whose button is gone too (the result has arrived); drop a highlight
    /// on a button the row no longer has.
    private func settleRowActions() {
        let agentsByID = Dictionary(presentation.agents.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        rowActionStates = rowActionStates.filter { id, state in
            guard let agent = agentsByID[id] else { return false }
            if case .completed(let button) = state { return RowButtons.usableButtons(for: agent).contains(button) }
            return true
        }
        if let agent = selectedAgent {
            highlightedButton = RowButtonHighlight.reconciled(highlightedButton, in: RowButtons.usableButtons(for: agent))
        } else {
            highlightedButton = nil
        }
    }

    private func isConfirming(_ agentID: String) -> Bool {
        if case .confirming? = rowActionStates[agentID] { return true }
        return false
    }

    private func cancelConfirmation(for agentID: String) {
        if isConfirming(agentID) { rowActionStates[agentID] = nil }
    }

    private func cancelConfirmations() {
        rowActionStates = rowActionStates.filter { _, state in
            if case .confirming = state { return false }
            return true
        }
    }

    /// A switch worked: count it toward the agent's ranking.
    func recordSwitch(to agentID: String) {
        frecency = FrecencyStore.recordingVisit(to: agentID, in: frecency, now: now())
        store.save(frecency)
        rebuild()
    }

    /// A switch failed: show why, in the panel, for a few seconds. Not counted
    /// toward ranking (a dead pane must not float to the top).
    func reportSwitchFailure(_ message: String) {
        showTransientNotice(.switchFailed(message))
    }

    /// The buttons the keyboard and mouse can use on `agent`'s row: none while its answer or decision is on its way.
    private func usableButtons(for agent: AgentSnapshot) -> [RowButton] {
        sendingLabel(for: agent) != nil ? [] : RowButtons.usableButtons(for: agent)
    }

    /// What the row says in place of its buttons while an answer or decision is on its way; nil when none is.
    func sendingLabel(for agent: AgentSnapshot) -> String? {
        if answer.isAwaiting(agent) { return "Sending answer…" }
        return permission.sendingLabel(for: agent)
    }

    /// A digit typed while a card is open: picks that option on it (the search box types nothing).
    func handleCardDigit(_ number: Int) {
        if answer.isOpen { answer.handle(.digit(number)) }
        else if permission.isOpen { permission.handle(.digit(number)) }
    }

    /// Any other character typed while a card is open: dropped (it still cancels a pending "Allow always").
    func handleCardStrayKey() {
        if permission.isOpen { permission.handle(.other) }
    }

    /// How long an answer's outcome stays in the footer: long enough to read a refusal in full.
    static let answerNoticeSeconds: TimeInterval = 8
    /// A refusal that arrived while the panel was away is shown once on the next summon within this time.
    static let answerNoticeRecallSeconds: TimeInterval = 60

    private func showAnswerNotice(_ sentence: String) {
        lastAnswerNotice = (sentence, now())
        showTransientNotice(.actionFailed(sentence), seconds: Self.answerNoticeSeconds)
    }

    private func repostRecentAnswerNotice() {
        guard let notice = lastAnswerNotice else { return }
        lastAnswerNotice = nil
        guard now().timeIntervalSince(notice.at) < Self.answerNoticeRecallSeconds else { return }
        showTransientNotice(.actionFailed(notice.sentence), seconds: Self.answerNoticeSeconds)
    }

    /// A row button failed: show why for a few seconds, like a failed switch.
    private func showTransientNotice(_ notice: PanelFooterNotice, seconds: TimeInterval? = nil) {
        transientNotice = notice
        refreshFooterNotice()
        switchErrorClearTask?.cancel()
        let seconds = seconds ?? switchErrorSeconds
        switchErrorClearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.clearTransientNotice()
        }
    }

    /// The global shortcut could not be registered; shown until the app quits.
    func reportHotkeyIssue(_ message: String?) {
        hotkeyIssue = message
        refreshFooterNotice()
    }

    private func clearTransientNotice() {
        switchErrorClearTask?.cancel()
        switchErrorClearTask = nil
        guard transientNotice != nil else { return }
        transientNotice = nil
        refreshFooterNotice()
    }

    private func refreshFooterNotice() {
        footerNotice = PanelFooterNotice.resolve(transient: transientNotice, hotkeyIssue: hotkeyIssue)
    }

    /// Compares Needs you with the previous reading and reports newcomers.
    private func trackNeedsYou(reportingArrivals: Bool = true) {
        let needsYou = AgentListBuilder.needsYouAgents(snapshot: snapshot, settings: listSettings, triage: triage)
        let arrivals = arrivalDetector.observe(needsYou)
        guard reportingArrivals, let needsYou,
              let content = CornerTabContent.forArrivals(arrivals, among: needsYou) else { return }
        onNeedsYouArrival(content)
    }

    private func rebuild() {
        presentation = AgentListBuilder.presentation(
            snapshot: snapshot, query: query, frecency: frecency, now: now(), settings: listSettings, triage: triage
        )
    }
}
