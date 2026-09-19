import Foundation
import Combine
import CommandBarKit

/// Observable state behind the panel: the latest snapshot, the search text,
/// the selection, the user's frecency and parked agents, and the row buttons
/// (Done / Park / Close pane). All derivation lives in the pure
/// `AgentListBuilder` / `AgentSelection` / `FrecencyStore` / `TriageState` /
/// `RowActionMachine`.
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
    var statusSource: (any AgentStatusSource)?

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
    private let peekLoader = PanePeekLoader()

    init(
        store: FrecencyStore = FrecencyStore(),
        triageStore: TriageStore = TriageStore(),
        listSettings: AgentListSettings = .standard,
        dashboardAddress: String = DashboardEndpoint(baseURL: DashboardEndpoint.defaultBaseURL).displayAddress,
        switchErrorSeconds: TimeInterval = 6,
        completedHoldSeconds: TimeInterval = 8,
        now: @escaping () -> Date = { Date() }
    ) {
        self.store = store
        self.triageStore = triageStore
        self.triage = triageStore.load()
        self.completedHoldSeconds = completedHoldSeconds
        self.listSettings = listSettings
        self.dashboardAddress = dashboardAddress
        self.switchErrorSeconds = switchErrorSeconds
        self.now = now
        self.frecency = store.load(now: now())
    }

    func receive(_ snapshot: StatusSnapshot) {
        self.snapshot = snapshot
        // A dead feed shows no agents; that must not read as "they all went away".
        if !snapshot.health.isDown, triage.observe(snapshot.agents) { triageStore.save(triage) }
        rebuild()
        selectedAgentID = AgentSelection.reconciled(selectedAgentID, in: presentation.selectableAgentIDs)
        settleRowActions()
        closePeekUnlessStillSelected()
    }

    /// New list settings: re-derive the list, keeping the selection while it survives.
    func apply(_ settings: AgentListSettings) {
        guard settings != listSettings else { return }
        listSettings = settings
        rebuild()
        selectedAgentID = AgentSelection.reconciled(selectedAgentID, in: presentation.selectableAgentIDs)
        closePeekUnlessStillSelected()
    }

    /// The status feed now comes from another dashboard: forget the old feed's
    /// agents and wait for the new one's first update.
    func useDashboard(address: String) {
        dashboardAddress = address
        snapshot = nil
        rowActionStates = [:]
        rebuild()
        selectedAgentID = nil
        closePeek()
    }

    /// Fresh start for each summon: empty search, first row selected.
    func resetForShow() {
        clearTransientNotice()
        closePeek()
        cancelConfirmations()
        query = ""
        rebuild()
        selectedAgentID = presentation.selectableAgentIDs.first
        focusRequest += 1
    }

    func moveSelection(by step: Int) {
        closePeek()
        selectedAgentID = AgentSelection.moved(from: selectedAgentID, by: step, in: presentation.selectableAgentIDs)
    }

    /// Hover: only rows that can be activated take the highlight.
    func select(agentID: String) {
        guard presentation.selectableAgentIDs.contains(agentID) else { return }
        selectedAgentID = agentID
        closePeekUnlessStillSelected()
    }

    /// Space. Peeks at the selected agent's screen, or closes the peek. Only
    /// with an empty search: otherwise it is a literal space in the query, and
    /// this returns false so the field types it.
    @discardableResult
    func togglePeek() -> Bool {
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
        peekLoader.load(paneId: paneId, from: statusSource) { [weak self] result in
            self?.peek?.content = PanePeek.content(from: result)
        }
    }

    private func closePeekUnlessStillSelected() {
        if peek?.agentID != selectedAgentID { closePeek() }
    }

    /// Enter: presses the highlighted button, or with none highlighted switches to the agent.
    func activateSelected() {
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
        guard peek == nil, let agent = selectedAgent else { return true }
        let previous = highlightedButton
        highlightedButton = RowButtonHighlight.moved(from: previous, by: step, in: RowButtons.usableButtons(for: agent))
        if previous != nil, highlightedButton == nil { cancelConfirmation(for: agent.id) }
        return true
    }

    /// Esc: backs out of the button level (un-highlights, cancels a pending
    /// confirmation). False when there was nothing to back out of, so Esc
    /// goes on to close the peek / panel.
    func backOutOfButtons() -> Bool {
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
              RowButtons.usableButtons(for: agent).contains(button) else { return nil }
        switch RowActionMachine.plan(pressing: button, current: rowActionStates[agentID]) {
        case .ignore:
            return nil
        case .park:
            setParked(true, agentID: agentID)
            return nil
        case .unpark:
            setParked(false, agentID: agentID)
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

    /// A row button failed: show why for a few seconds, like a failed switch.
    private func showTransientNotice(_ notice: PanelFooterNotice) {
        transientNotice = notice
        refreshFooterNotice()
        switchErrorClearTask?.cancel()
        let seconds = switchErrorSeconds
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

    private func rebuild() {
        presentation = AgentListBuilder.presentation(
            snapshot: snapshot, query: query, frecency: frecency, now: now(), settings: listSettings, triage: triage
        )
    }
}
