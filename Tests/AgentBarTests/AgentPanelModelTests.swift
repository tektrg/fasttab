import Foundation
import Testing
import CommandBarKit
@testable import AgentBar

@MainActor
struct AgentPanelModelTests {
    typealias F = AgentListFixtures

    private func makeModel() -> AgentPanelModel {
        let suite = "AgentBarTests.\(UUID().uuidString)"
        let store = FrecencyStore(defaults: UserDefaults(suiteName: suite)!)
        return AgentPanelModel(store: store, now: { F.now })
    }

    private let snapshot = F.snapshot([
        F.agent("n1", label: "alpha", section: .needsYou),
        F.agent("w1", label: "beta", section: .working),
        F.agent("w2", label: "alpine", section: .working),
        F.agent("e1", label: "old", section: .ended)
    ])

    @Test func startsConnectingThenFirstRowIsSelected() {
        let model = makeModel()
        #expect(model.presentation.state == .connecting)
        #expect(model.selectedAgentID == nil)
        model.receive(snapshot)
        #expect(model.selectedAgentID == "n1")
    }

    @Test func arrowsMoveAcrossSectionsSkippingEnded() {
        let model = makeModel()
        model.receive(snapshot)
        model.moveSelection(by: 1)
        model.moveSelection(by: 1)
        #expect(model.selectedAgentID == "w2")
        model.moveSelection(by: 1)
        #expect(model.selectedAgentID == "n1")
    }

    @Test func typingResetsSelectionToFirstMatch() {
        let model = makeModel()
        model.receive(snapshot)
        model.moveSelection(by: 1)
        model.query = "alp"
        #expect(model.presentation.agents.map(\.id) == ["n1", "w2"])
        #expect(model.selectedAgentID == "n1")
        model.query = "zzz"
        #expect(model.presentation.state == .noMatches)
        #expect(model.selectedAgentID == nil)
    }

    @Test func refreshKeepsSelectionWhileItSurvivesElseFallsToFirst() {
        let model = makeModel()
        model.receive(snapshot)
        model.select(agentID: "w1")
        model.receive(snapshot)
        #expect(model.selectedAgentID == "w1")
        model.receive(F.snapshot([F.agent("n1", section: .needsYou)]))
        #expect(model.selectedAgentID == "n1")
    }

    @Test func feedDownClearsSelection() {
        let model = makeModel()
        model.receive(snapshot)
        model.receive(F.snapshot([], health: .down(reason: "x"), boardIsCurrent: false))
        #expect(model.selectedAgentID == nil)
        #expect(model.presentation.state == .feedDown(reason: "x"))
    }

    @Test func hoverIgnoresEndedRows() {
        let model = makeModel()
        model.receive(snapshot)
        model.select(agentID: "e1")
        #expect(model.selectedAgentID == "n1")
    }

    @Test func activatingRecordsFrecencyAndReRanksNextTime() {
        let model = makeModel()
        var activated: [String] = []
        model.onActivate = { activated.append($0.id) }
        model.receive(snapshot)
        model.select(agentID: "w2")
        model.activateSelected()
        #expect(activated == ["w2"])
        #expect(model.presentation.agents.map(\.id) == ["n1", "w2", "w1", "e1"])
    }

    @Test func endedRowCannotBeActivated() {
        let model = makeModel()
        var activated = 0
        model.onActivate = { _ in activated += 1 }
        model.receive(snapshot)
        model.activate(agentID: "e1")
        #expect(activated == 0)
    }

    @Test func resetForShowClearsQueryAndSelectsFirst() {
        let model = makeModel()
        model.receive(snapshot)
        model.query = "beta"
        model.resetForShow()
        #expect(model.query.isEmpty)
        #expect(model.selectedAgentID == "n1")
    }
}
