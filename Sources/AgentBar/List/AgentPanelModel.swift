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

    /// Called after the user activates a row (Enter or click), once frecency is
    /// recorded. The host closes the panel and (slice 4) focuses the agent.
    var onActivate: (AgentSnapshot) -> Void = { _ in }

    private let store: FrecencyStore
    private let now: () -> Date
    private var frecency: [String: FrecencyEntry]

    init(store: FrecencyStore = FrecencyStore(), now: @escaping () -> Date = { Date() }) {
        self.store = store
        self.now = now
        self.frecency = store.load(now: now())
    }

    func receive(_ snapshot: StatusSnapshot) {
        self.snapshot = snapshot
        rebuild()
        selectedAgentID = AgentSelection.reconciled(selectedAgentID, in: presentation.selectableAgentIDs)
    }

    /// Fresh start for each summon: empty search, first row selected.
    func resetForShow() {
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
        frecency = FrecencyStore.recordingVisit(to: agent.id, in: frecency, now: now())
        store.save(frecency)
        rebuild()
        onActivate(agent)
    }

    private func rebuild() {
        presentation = AgentListBuilder.presentation(
            snapshot: snapshot, query: query, frecency: frecency, now: now()
        )
    }
}
