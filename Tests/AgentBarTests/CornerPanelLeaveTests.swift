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

    @Test func typingSlashShowsCommandRowsThatNarrow() {
        let model = makeModel()
        model.query = "/"
        #expect(model.commandRows.map(\.id) == ["new", "view"])
        model.query = "/v"
        #expect(model.commandRows.map(\.id) == ["view"])
        model.query = "/regex/"
        #expect(model.commandRows.isEmpty)
        model.query = "new"
        #expect(model.commandRows.isEmpty)
    }

    @Test func arrowsMoveTheHighlightAndReturnRunsIt() {
        let model = makeModel()
        model.query = "/"
        #expect(model.highlightedCommand?.id == "new")
        #expect(model.moveCommandHighlight(by: 1))
        #expect(model.highlightedCommand?.id == "view")
        #expect(model.moveCommandHighlight(by: 1))   // wraps
        #expect(model.highlightedCommand?.id == "new")
        model.moveSelectionOrAnswerHighlight(by: -1)
        #expect(model.highlightedCommand?.id == "view")
        model.activateSelected()
        #expect(model.pages.editor != nil)   // /view ran: the new-view editor is open
        #expect(model.commandRows.isEmpty)
    }

    @Test func pickingNewRunsNewWorkerMode() {
        let model = makeModel()
        model.query = "/n"
        model.run(model.commandRows[0])
        #expect(model.newWorker != nil)
        #expect(model.commandRows.isEmpty)
    }

    @Test func exactTextAndReturnStillWorks() {
        let model = makeModel()
        model.query = " /VIEW "
        model.activateSelected()
        #expect(model.pages.editor != nil)
    }

    @Test func noRowsWhileTagOrEditorOwnsTheBox() {
        let model = makeModel()
        model.pages.beginNew()
        model.query = "/"
        #expect(model.commandRows.isEmpty)
    }
}

