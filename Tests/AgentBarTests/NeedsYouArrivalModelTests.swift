import Foundation
import Testing
import CommandBarKit
@testable import AgentBar

/// The model turns "an agent entered Needs you, as the user sees it" into a corner-tab call.
@MainActor
struct NeedsYouArrivalModelTests {
    typealias F = AgentListFixtures

    private func makeModel() -> (AgentPanelModel, () -> [CornerTabContent]) {
        let defaults = makeScratchDefaults("arrivals")
        let model = AgentPanelModel(
            store: FrecencyStore(defaults: defaults),
            triageStore: TriageStore(defaults: defaults),
            now: { F.now }
        )
        var reported: [CornerTabContent] = []
        model.onNeedsYouArrival = { reported.append($0) }
        return (model, { reported })
    }

    private func needsYou(_ ids: String...) -> StatusSnapshot {
        F.snapshot(ids.map { F.agent($0, label: "agent-\($0)", section: .needsYou, secondsInStatus: 30) })
    }

    @Test func theFirstSnapshotIsOnlyABaseline() {
        let (model, reported) = makeModel()
        model.receive(needsYou("a", "b"))
        #expect(reported().isEmpty)
    }

    @Test func aNewNeedsYouAgentIsReportedWithTheTotalAndItsName() {
        let (model, reported) = makeModel()
        model.receive(needsYou("a"))
        model.receive(needsYou("a", "b"))
        #expect(reported() == [CornerTabContent(count: 2, newestName: "agent-b")])
    }

    @Test func aWorkingAgentFinishingCountsAsNew() {
        let (model, reported) = makeModel()
        model.receive(F.snapshot([F.agent("a", section: .working), F.agent("b", section: .needsYou)]))
        model.receive(F.snapshot([F.agent("a", label: "done-one", section: .needsYou), F.agent("b", section: .needsYou)]))
        #expect(reported() == [CornerTabContent(count: 2, newestName: "done-one")])
    }

    @Test func aDownFeedAndItsRecoveryStartAgainFromABaseline() {
        let (model, reported) = makeModel()
        model.receive(needsYou("a"))
        model.receive(.down(reason: "unreachable", at: F.now))
        model.receive(needsYou("a", "b"))
        #expect(reported().isEmpty)
        model.receive(needsYou("a", "b", "c"))
        #expect(reported().count == 1)
    }

    @Test func switchingDashboardStartsAgainFromABaseline() {
        let (model, reported) = makeModel()
        model.receive(needsYou("a"))
        model.useDashboard(address: "127.0.0.1:9999")
        model.receive(needsYou("a", "b"))
        #expect(reported().isEmpty)
    }

    @Test func aSearchDoesNotHideArrivals() {
        let (model, reported) = makeModel()
        model.receive(needsYou("a"))
        model.query = "zzz"
        model.receive(needsYou("a", "b"))
        #expect(reported().count == 1)
    }

    @Test func parkingIsADepartureAndUnparkingIsAnArrival() {
        let (model, reported) = makeModel()
        // No hook data = cannot take Compact, so Park sends nothing and Unpark is not blocked by an in-flight /compact.
        let noCompact = F.snapshot(["a", "b"].map { F.agent($0, label: "agent-\($0)", section: .needsYou, hasHookData: false, secondsInStatus: 30) })
        model.receive(noCompact)
        model.press(.park, on: "a")
        #expect(reported().isEmpty)
        model.press(.unpark, on: "a")
        #expect(reported() == [CornerTabContent(count: 2, newestName: "agent-a")])
    }

    @Test func revealingAgentsThroughASettingIsNotAnArrival() {
        let (model, reported) = makeModel()
        var hidden = AgentListSettings.standard
        hidden.showsNonClaudePanes = false
        model.apply(hidden)
        model.receive(F.snapshot([F.agent("a"), F.agent("shell", hasHookData: false)]))
        model.apply(.standard)
        #expect(reported().isEmpty)
        model.receive(F.snapshot([F.agent("a"), F.agent("shell", hasHookData: false), F.agent("b")]))
        #expect(reported().count == 1)
    }
}
