import Foundation
import Testing
import IndieCommandBar
@testable import AgentBar

/// Gap 9: corner-opened panel closes on pointer leave only when nothing is in progress.
/// Gap 11: Agent Bar's slash commands on the shared command-row hook, unchanged behaviour.
@MainActor
struct CornerPanelLeaveTests {
    private func makeModel() -> AgentPanelModel {
        let suite = "CornerPanelLeaveTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let pages = AgentPagesModel(store: AgentSavedViewStore(defaults: defaults))
        return AgentPanelModel(store: FrecencyStore(defaults: defaults), pages: pages, now: { AgentListFixtures.now })
    }

    @Test func cornerZoneIsTheDisplaysBottomRight() {
        let zone = CornerPanelLeave.cornerZone(displayFrame: CGRect(x: 0, y: 0, width: 1000, height: 800))
        #expect(zone.maxX == 1000 && zone.minY == 0 && zone.width == CornerHotZone.size * 2)
    }

    @Test func idlePanelMayCloseButTypingAndEditorsHoldIt() {
        let model = makeModel()
        #expect(model.isSearchBoxEmptyForPointerLeave)
        #expect(!model.holdsPanelAgainstPointerLeave)
        model.query = "x"
        #expect(!model.isSearchBoxEmptyForPointerLeave)
        model.query = ""
        model.pages.beginNew()
        #expect(model.holdsPanelAgainstPointerLeave)
    }

    @Test func newWorkerModeHoldsThePanel() {
        let model = makeModel()
        model.enterNewWorkerMode()
        #expect(model.holdsPanelAgainstPointerLeave)
    }

    @Test func slashCommandsResolveAsBefore() {
        #expect(AgentBarCommands.exact("/new") == AgentBarCommands.newWorker)
        #expect(AgentBarCommands.exact(" /VIEW ") == AgentBarCommands.newView)
        #expect(AgentBarCommands.exact("/newer") == nil)
        #expect(AgentBarCommands.exact("/regex/") == nil)
        #expect(CommandBarCommandRows.matching("/", in: AgentBarCommands.all).count == 2)
    }
}
