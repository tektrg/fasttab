import Foundation
import Testing
import IndieAgentSessions
@testable import AgentBar

/// `agentbar://session/<rowId>`: another app (MacLanes) asks AgentBar to show a session.
@MainActor
struct SessionLinkTests {
    typealias F = AgentListFixtures

    private func makeModel() -> AgentPanelModel {
        let suite = "AgentBarTests.\(UUID().uuidString)"
        return AgentPanelModel(store: FrecencyStore(defaults: UserDefaults(suiteName: suite)!), now: { F.now })
    }

    private func agent(_ id: String, rowId: String, section: AgentSection) -> AgentSnapshot {
        var agent = F.agent(id, label: id, section: section)
        agent.rowId = rowId
        return agent
    }

    private var snapshot: StatusSnapshot {
        F.snapshot([
            agent("n1", rowId: "row-n1", section: .needsYou),
            agent("w1", rowId: "row-w1", section: .working),
            agent("w2", rowId: "row-w2", section: .working),
        ])
    }

    @Test func parsesTheLinkAppsBuild() throws {
        let link = AgentSessionLink()
        let url = try #require(link.url(for: "716b90f8-8e62 /x"))
        #expect(url.scheme == "agentbar")
        #expect(link.sessionID(from: url) == "716b90f8-8e62 /x")
        #expect(link.sessionID(from: URL(string: "agentbar://settings")!) == nil)
        #expect(link.sessionID(from: URL(string: "agentbar://session/%24%28echo%20INJECTED%29")!) == "$(echo INJECTED)")
    }

    @Test func selectsTheRowByRowIdAsIfArrowedTo() {
        let model = makeModel()
        model.receive(snapshot)
        model.resetForShow()
        #expect(model.selectedAgentID == "n1")
        model.revealSession(id: "row-w2")
        #expect(model.selectedAgentID == "w2")
        #expect(model.footerNotice == nil)
    }

    @Test func alsoAcceptsTheRowsOwnId() {
        let model = makeModel()
        model.receive(snapshot)
        model.revealSession(id: "w1")
        #expect(model.selectedAgentID == "w1")
    }

    @Test func anUnknownSessionKeepsThePanelAndSaysItIsNotRunning() {
        let model = makeModel()
        model.receive(snapshot)
        model.resetForShow()
        model.revealSession(id: "row-gone")
        #expect(model.selectedAgentID == "n1")
        #expect(model.footerNotice?.text == AgentPanelModel.sessionNotRunningNotice)
    }

    @Test func aLinkBeforeTheFirstReadingWaitsForIt() {
        let model = makeModel()
        model.revealSession(id: "row-w1")
        #expect(model.footerNotice == nil)
        model.receive(snapshot)
        #expect(model.selectedAgentID == "w1")
        model.moveSelection(by: -1)
        model.receive(snapshot)   // applied once only
        #expect(model.selectedAgentID == "n1")
    }

    @Test func aLinkBeforeTheFirstReadingForAGoneSessionShowsTheNotice() {
        let model = makeModel()
        model.revealSession(id: "row-gone")
        model.receive(snapshot)
        #expect(model.footerNotice?.text == AgentPanelModel.sessionNotRunningNotice)
    }

    @Test func aRestingPointerDoesNotStealTheLinkedRowRightAway() {
        var clock = F.now
        let suite = "AgentBarTests.\(UUID().uuidString)"
        let model = AgentPanelModel(store: FrecencyStore(defaults: UserDefaults(suiteName: suite)!), now: { clock })
        model.receive(snapshot)
        model.revealSession(id: "row-w2")
        model.select(agentID: "n1")   // hover fired by the panel appearing under the pointer
        #expect(model.selectedAgentID == "w2")
        clock = clock.addingTimeInterval(AgentPanelModel.sessionLinkHoverGraceSeconds + 0.1)
        model.select(agentID: "n1")   // a real hover later still works
        #expect(model.selectedAgentID == "n1")
    }
}
