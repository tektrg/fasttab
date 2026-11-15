import Testing
@testable import AgentBar

/// The shared action row's items are the row's ⋯ menu, item for item (plus Close / Go to agent),
/// and its overflow split never wraps: what does not fit goes to "More…".
struct AgentActionListTests {
    typealias F = AgentListFixtures

    private func menuTitles(_ agent: AgentSnapshot, tree: AgentTree? = nil) -> [String] {
        let menu = RowMoreMenuView(items: AgentActionList.menuItems(for: agent, tree: tree), isHighlighted: false, onSelect: { _ in })
        return RowMoreMenuView.actions(for: menu.menuContent).map(\.title)
    }

    @Test(arguments: [
        F.agent("idle"),                                   // needs you, not blocked
        F.agent("work", section: .working),
        F.agent("park", section: .parked),
        AnswerFixtures.blockedAgent("q", blocker: .question(AnswerFixtures.question())),
        F.agent("end", section: .ended),
    ])
    func rowItemsMatchTheMoreMenuOneForOne(agent: AgentSnapshot) {
        let row = AgentActionList.items(for: agent, tree: nil)
        #expect(row.prefix(2).map(\.action) == [.close, .goToAgent])
        #expect(row.dropFirst(2).map(\.title) == menuTitles(agent))
        let menuButtons = AgentActionList.menuItems(for: agent, tree: nil).map(\.button)
        #expect(row.dropFirst(2).map(\.action) == menuButtons.map(AgentAction.row))
    }

    @Test func menuItemsAreTheMovedCapsulesThenTheMenusOwnThenTree() {
        let agent = F.agent("idle")
        let expected = RowButtons.movedIntoMenu(RowButtons.available(for: agent)) + RowButtons.menuItems(for: agent)
        #expect(AgentActionList.menuItems(for: agent, tree: nil) == expected)
        #expect(expected.map(\.button).contains(.peek))
        #expect(expected.map(\.button).contains(.park))
    }

    @Test func hidingAndGoToReason() {
        let agent = F.agent("idle")
        let row = AgentActionList.items(for: agent, tree: nil, goToDisabledReason: "No known home", hiding: [.peek])
        #expect(!row.map(\.action).contains(.row(.peek)))
        let goTo = row.first { $0.action == .goToAgent }
        #expect(goTo?.isEnabled == false)
        #expect(goTo?.help == "No known home")
        #expect(!AgentActionList.items(for: agent, tree: nil, includesGoTo: false).map(\.action).contains(.goToAgent))
    }
}

struct AgentActionCandidateTests {
    @Test func triesAllThenFewer() {
        #expect(AgentActionList.candidateCounts(itemCount: 3) == [3, 2, 1, 0])
        #expect(AgentActionList.candidateCounts(itemCount: 0) == [0])
    }
}

/// "More…" overflow entries show the same confirm/busy/done words as the inline capsules (M1).
struct AgentActionMoreTitleTests {
    private func item(_ button: RowButton) -> AgentActionItem {
        let spec = RowButtonSpec(button: button, disabledReason: nil)
        return AgentActionItem(action: .row(button), title: spec.label, isEnabled: true, help: nil, spec: spec)
    }

    @Test func doneShowsConfirmThenBusyInTheMoreMenu() {
        let done = item(.done)
        #expect(AgentActionList.overflowTitle(of: done, state: nil) == done.title)
        #expect(AgentActionList.overflowTitle(of: done, state: .confirming(.done, reason: "x"))
            == RowActionButtonView.titles(for: done.spec!).confirming)
        #expect(AgentActionList.overflowTitle(of: done, state: .busy(.done))
            == RowActionButtonView.titles(for: done.spec!).busy)
        #expect(AgentActionList.overflowIsEnabled(done, state: .busy(.done)) == false)
        #expect(AgentActionList.overflowIsEnabled(done, state: .confirming(.done, reason: "")) == true)
    }

    @Test func closePaneConfirmDoesNotLeakToOtherItems() {
        let close = item(.closePane), park = item(.park)
        #expect(AgentActionList.overflowTitle(of: close, state: .confirming(.closePane, reason: ""))
            == RowActionText.title(of: .closePane, state: .confirming(.closePane, reason: "")))
        #expect(AgentActionList.overflowTitle(of: park, state: .confirming(.closePane, reason: "")) == park.title)
        let goTo = AgentActionItem(action: .goToAgent, title: "Go to agent", isEnabled: true, help: nil, spec: nil)
        #expect(AgentActionList.overflowTitle(of: goTo, state: .busy(.done)) == "Go to agent")
    }
}
