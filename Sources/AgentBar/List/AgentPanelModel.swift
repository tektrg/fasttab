import Foundation
import Combine
import CommandBarKit

/// Observable state behind the panel: the latest snapshot, the search text,
/// the selection and the user's frecency. All derivation lives in the pure
/// `AgentListBuilder` / `AgentSelection` / `FrecencyStore`.
@MainActor
final class AgentPanelModel: ObservableObject {
    @Published private(set) var snapshot: StatusSnapshot?
    @Published private(set) var presentation: AgentListPresentation = .connecting
    @Published private(set) var selectedAgentID: String?
    /// Bumped on every show so the search field re-grabs keyboard focus.
    @Published private(set) var focusRequest = 0
    /// Typing re-filters and always jumps back to the first row.
    @Published var query = "" {
        didSet {
            guard query != oldValue else { return }
            rebuild()
            selectedAgentID = presentation.selectableAgentIDs.first
        }
    }

    /// Strip at the bottom of the panel: a failed switch, else a shortcut problem.
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
    private let now: () -> Date
    private let switchErrorSeconds: TimeInterval
    private var frecency: [String: FrecencyEntry]
    private var switchError: String?
    private var hotkeyIssue: String?
    private var switchErrorClearTask: Task<Void, Never>?

    init(
        store: FrecencyStore = FrecencyStore(),
        listSettings: AgentListSettings = .standard,
        dashboardAddress: String = DashboardEndpoint(baseURL: DashboardEndpoint.defaultBaseURL).displayAddress,
        switchErrorSeconds: TimeInterval = 6,
        now: @escaping () -> Date = { Date() }
    ) {
        self.store = store
        self.listSettings = listSettings
        self.dashboardAddress = dashboardAddress
        self.switchErrorSeconds = switchErrorSeconds
        self.now = now
        self.frecency = store.load(now: now())
    }

    func receive(_ snapshot: StatusSnapshot) {
        self.snapshot = snapshot
        rebuild()
        selectedAgentID = AgentSelection.reconciled(selectedAgentID, in: presentation.selectableAgentIDs)
    }

    /// New list settings: re-derive the list, keeping the selection while it survives.
    func apply(_ settings: AgentListSettings) {
        guard settings != listSettings else { return }
        listSettings = settings
        rebuild()
        selectedAgentID = AgentSelection.reconciled(selectedAgentID, in: presentation.selectableAgentIDs)
    }

    /// The status feed now comes from another dashboard: forget the old feed's
    /// agents and wait for the new one's first update.
    func useDashboard(address: String) {
        dashboardAddress = address
        snapshot = nil
        rebuild()
        selectedAgentID = nil
    }

    /// Fresh start for each summon: empty search, first row selected.
    func resetForShow() {
        clearSwitchError()
        query = ""
        rebuild()
        selectedAgentID = presentation.selectableAgentIDs.first
        focusRequest += 1
    }

    func moveSelection(by step: Int) {
        selectedAgentID = AgentSelection.moved(from: selectedAgentID, by: step, in: presentation.selectableAgentIDs)
    }

    /// Hover: only rows that can be activated take the highlight.
    func select(agentID: String) {
        guard presentation.selectableAgentIDs.contains(agentID) else { return }
        selectedAgentID = agentID
    }

    func activateSelected() {
        guard let selectedAgentID else { return }
        activate(agentID: selectedAgentID)
    }

    func activate(agentID: String) {
        guard presentation.selectableAgentIDs.contains(agentID),
              let agent = presentation.agents.first(where: { $0.id == agentID })
        else { return }
        onActivate(agent)
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
        switchError = message
        refreshFooterNotice()
        switchErrorClearTask?.cancel()
        let seconds = switchErrorSeconds
        switchErrorClearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.clearSwitchError()
        }
    }

    /// The global shortcut could not be registered; shown until the app quits.
    func reportHotkeyIssue(_ message: String?) {
        hotkeyIssue = message
        refreshFooterNotice()
    }

    private func clearSwitchError() {
        switchErrorClearTask?.cancel()
        switchErrorClearTask = nil
        guard switchError != nil else { return }
        switchError = nil
        refreshFooterNotice()
    }

    private func refreshFooterNotice() {
        footerNotice = PanelFooterNotice.resolve(switchError: switchError, hotkeyIssue: hotkeyIssue)
    }

    private func rebuild() {
        presentation = AgentListBuilder.presentation(
            snapshot: snapshot, query: query, frecency: frecency, now: now(), settings: listSettings
        )
    }
}
