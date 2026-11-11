import Foundation
import SwiftUI
import Testing
import IndieCommandBar
@testable import AgentBar

/// Pins Agent Bar's panel behaviour before it moves onto the shared IndieCommandBar shell
/// (slice 8): keys, footer hints, page tabs and switching, rows and selection, closing.
@MainActor
struct AgentShellCharacterizationTests {
    typealias F = AgentListFixtures

    private func makeModel() -> AgentPanelModel {
        let store = FrecencyStore(defaults: UserDefaults(suiteName: "AgentShellChar.\(UUID().uuidString)")!)
        return AgentPanelModel(store: store, now: { F.now })
    }

    private func pagesModel() -> AgentPagesModel {
        AgentPagesModel(store: AgentSavedViewStore(defaults: UserDefaults(suiteName: "AgentShellCharPages.\(UUID().uuidString)")!))
    }

    // MARK: Keys

    @Test func returnRoutesOnlyWithShiftAndNoCard() {
        #expect(AgentPanelKeys.returnAction(shift: true, isCardOpen: false) == .startRouting)
        #expect(AgentPanelKeys.returnAction(shift: false, isCardOpen: false) == .activateSelected)
        #expect(AgentPanelKeys.returnAction(shift: true, isCardOpen: true) == .activateSelected)
    }

    @Test func cardKeysPickDigitsCopyAndDropTheRest() {
        func key(_ c: String, _ m: EventModifiers = [], nav: Bool = false, open: Bool = true) -> AgentPanelKeys.CardKey {
            AgentPanelKeys.cardKey(characters: c, modifiers: m, isNavigationKey: nav, isCardOpen: open)
        }
        #expect(key("3") == .pickOption(3))
        #expect(key("9") == .pickOption(9))
        #expect(key("0") == .dropStray)
        #expect(key("x") == .dropStray)
        #expect(key("X", .shift) == .dropStray)
        #expect(key("c", .command) == .copyIdentity)
        #expect(key(",", .command) == .ignored)   // ⌘, Settings passes through
        #expect(key(" ", nav: true) == .ignored)
        #expect(key("3", open: false) == .ignored)
        #expect(key("c", .command, open: false) == .ignored)
    }

    @Test func escapePeelsNoticeThenButtonsThenPeekThenCloses() {
        #expect(AgentPanelKeys.escape(dismissNotice: { true }, backOutOfButtons: { true }, hasPeek: true) == .dismissedNotice)
        #expect(AgentPanelKeys.escape(dismissNotice: { false }, backOutOfButtons: { true }, hasPeek: true) == .backedOutOfButtons)
        #expect(AgentPanelKeys.escape(dismissNotice: { false }, backOutOfButtons: { false }, hasPeek: true) == .closedPeek)
        #expect(AgentPanelKeys.escape(dismissNotice: { false }, backOutOfButtons: { false }, hasPeek: false) == .closePanel)
    }

    @Test func hiddenShortcutsFollowState() {
        let all = AgentPanelKeys.shortcuts(isNewWorker: false, focusCount: 2, queryIsEmpty: true, canSwitchPages: true)
        #expect(all.isSuperset(of: [.focus, .reportTo, .stopReporting, .stopReportingDelete, .page(1), .page(9)]))
        let typing = AgentPanelKeys.shortcuts(isNewWorker: false, focusCount: 0, queryIsEmpty: false, canSwitchPages: false)
        #expect(typing == [.reportTo, .stopReporting])
        #expect(AgentPanelKeys.shortcuts(isNewWorker: true, focusCount: 3, queryIsEmpty: true, canSwitchPages: false).isEmpty)
    }

    // MARK: Footer hints

    @Test func footerHintWordsAreStable() {
        typealias H = PanelFooterHints
        #expect(H.text(for: .init()) == "↑↓ select   ←→ actions   space peek   ↩ switch   esc close")
        #expect(H.text(for: .init(searchIsEmpty: false)) == "↑↓ select   ↩ switch   esc close")
        #expect(H.text(for: .init(isPeeking: true)) == "space/esc back   ↩ switch")
        #expect(H.text(for: .init(hasHighlightedButton: true)) == "←→ button   ↩ press   esc back")
        #expect(H.text(for: .init(hasDismissibleNotice: true)) == "esc dismiss notice")
        #expect(H.text(for: .init(isTagged: true)) == "↩ send   tab retag   esc untag")
    }

    // MARK: Pages

    @Test func pageTabsTitlesIconsAndNumbers() {
        let pages = pagesModel()
        let view = AgentSavedView(name: "Workers")
        pages.store.add(view)
        let tabs = pages.tabs
        #expect(tabs.map(\.title) == ["All", "Workers", "New view"])
        #expect(tabs.map(\.shortcutNumber) == [1, 2, nil])
    }

    @Test func pagesStepClampsAndNewViewOpensEditor() {
        let pages = pagesModel()
        #expect(!pages.step(1))   // no saved views: no switching
        let view = AgentSavedView(name: "W")
        pages.store.add(view)
        #expect(!pages.step(-1))
        #expect(pages.step(1))
        #expect(pages.activePage == .custom(view.id))
        #expect(pages.step(1))   // onto New view: opens the new-view editor
        #expect(pages.activePage == .newView && pages.editor?.isNew == true)
    }

    @Test func flickSwitchesOncePerGestureLeftIsForward() {
        var flick = CommandBarViewFlick()
        let ordered = ["all", "a", "new"]
        var target: String?
        for _ in 0..<10 where target == nil {
            target = flick.handleScroll(deltaX: -10, isEnded: false, current: "all", ordered: ordered)
        }
        #expect(target == "a")
        #expect(flick.handleScroll(deltaX: -100, isEnded: false, current: "a", ordered: ordered) == nil)   // suppressed
        _ = flick.handleScroll(deltaX: 0, isEnded: true, current: "a", ordered: ordered)
        #expect(flick.handleScroll(deltaX: 80, isEnded: false, current: "a", ordered: ordered) == "all")
        #expect(flick.handleScroll(deltaX: 5, deltaY: 50, isEnded: true, current: "all", ordered: ordered) == nil)
    }

    // MARK: Rows, selection, closing

    @Test func rowsAndSelectionWrap() {
        let model = makeModel()
        model.receive(F.snapshot([
            F.agent("n1", label: "alpha", section: .needsYou),
            F.agent("w1", label: "beta", section: .working),
            F.agent("e1", label: "old", section: .ended)
        ]))
        #expect(model.presentation.agents.map(\.label) == ["alpha", "beta", "old"])
        #expect(model.selectedAgentID == "n1")
        model.moveSelection(by: -1)
        #expect(model.selectedAgentID == "w1")   // wraps to the last selectable (ended skipped)
        model.moveSelection(by: 1)
        #expect(model.selectedAgentID == "n1")
        #expect(AgentSelection.moved(from: nil, by: -1, in: ["a", "b"]) == "b")
        #expect(AgentSelection.moved(from: nil, by: 1, in: ["a", "b"]) == "a")
    }

    @Test func rowDimmingByStatus() {
        let ended = F.agent("e", section: .ended)
        let sleeping = F.agent("s", section: .sleeping)
        #expect(AgentRowView.dimming(of: sleeping, isSelected: false) == 0.55)
        #expect(AgentRowView.dimming(of: sleeping, isSelected: true) == 1)
        #expect([0.85, 0.45].contains(AgentRowView.dimming(of: ended, isSelected: false)))
    }

    @Test func showResetsQueryTagAndSelection() {
        let model = makeModel()
        model.receive(F.snapshot([F.agent("n1", section: .needsYou), F.agent("w1", section: .working)]))
        model.query = "w1"
        model.resetForShow()
        #expect(model.query.isEmpty)
        #expect(model.taggedAgentID == nil)
        #expect(model.selectedAgentID == "n1")
    }
}
