import SwiftUI
import Testing
@testable import AgentBar

/// ⌘K answer section: the pending question's options first, numbered, then the actions.
struct RowKeyMenuAnswerTests {
    typealias A = AnswerFixtures

    @Test func singleSelectOptionsComeFirstAndNumberingContinues() throws {
        let question = A.question(labels: ["Apple", "Banana"])
        let agent = A.blockedAgent("q", blocker: .question(question), paneId: "%1")
        let answers = RowKeyMenu.answerEntries(for: agent, isAwaiting: false)
        let items = [RowButtonSpec(button: .answer, disabledReason: nil), RowButtonSpec(button: .peek, disabledReason: nil),
                     RowButtonSpec(button: .park, disabledReason: nil)]
        var menu = try #require(RowKeyMenu(agentID: "q", answers: answers, questionIdentity: question.identity, items: items))
        #expect(menu.entries.map(\.label) == ["Apple", "Banana", RowKeyMenu.Entry.otherTitle, "Peek", "Park"])
        #expect(menu.answerCount == 3)
        #expect(menu.items.map(\.button) == [.peek, .park])   // the row's Answer is the section itself
        #expect(menu.highlighted == 0)
        #expect(menu.handle(.digit(2)) == .answer(optionIndex: 2))
        #expect(menu.handle(.digit(3)) == .answer(optionIndex: 3))   // Other → card typing (model)
        #expect(menu.handle(.digit(5)) == .activate(.park))
    }

    @Test func multiSelectHookFormAndPermissionGetOneAnswerItem() {
        let multi = A.blockedAgent("m", blocker: .question(A.question(multi: true)))
        #expect(RowKeyMenu.answerEntries(for: multi, isAwaiting: false) == [.openCard(.answer)])
        let loading = A.blockedAgent("l", blocker: .questionLoading(nil))
        #expect(RowKeyMenu.answerEntries(for: loading, isAwaiting: false) == [.reading])
        #expect(RowKeyMenu.answerEntries(for: A.blockedAgent("p", blocker: .permission), isAwaiting: false).isEmpty)
        let single = A.blockedAgent("s", blocker: .question(A.question()))
        #expect(RowKeyMenu.answerEntries(for: single, isAwaiting: true).isEmpty)
    }

    @Test func readingIsDisabledAndAnswerOpensCard() throws {
        var reading = try #require(RowKeyMenu(agentID: "l", answers: [.reading], items: [RowButtonSpec(button: .park, disabledReason: nil)]))
        #expect(reading.highlighted == 1)
        #expect(reading.handle(.digit(1)) == RowKeyMenu.Effect.none)
        var open = try #require(RowKeyMenu(agentID: "m", answers: [.openCard(.answer)], items: []))
        #expect(open.handle(.enter) == .activate(.answer))
    }

    @Test func beyondNineHasNoDigit() throws {
        let labels = (1...11).map { "Option \($0)" }
        let question = A.question(labels: labels, withOther: false)
        let agent = A.blockedAgent("q", blocker: .question(question))
        var menu = try #require(RowKeyMenu(agentID: "q", answers: RowKeyMenu.answerEntries(for: agent, isAwaiting: false), items: []))
        #expect(RowKeyMenu.number(at: 9) == nil)
        #expect(menu.handle(.digit(9)) == .answer(optionIndex: 9))
        for _ in 0..<12 { _ = menu.handle(.down) }
        #expect(menu.handle(.enter) == .answer(optionIndex: 11))
    }
}

@MainActor @Suite(.serialized)
struct RowKeyMenuAnswerModelTests {
    typealias A = AnswerFixtures

    private func setUp(_ purpose: String, _ question: AnswerableQuestion) -> (AgentPanelModel, PermissionFakeSource) {
        let model = RowKeyMenuModelTests.makeModel(purpose)
        let source = PermissionFakeSource()   // fake dashboard: never the real 127.0.0.1:4711
        source.screen = .screen(lines: ["$ ls"], readAt: AgentListFixtures.now)
        model.statusSource = source
        model.receive(AgentListFixtures.snapshot([A.blockedAgent("q", blocker: .question(question), paneId: "%1")]))
        model.select(agentID: "q")
        model.toggleKeyMenu()
        return (model, source)
    }

    @Test func pickingAnOptionSendsOnceThroughTheCard() async throws {
        let (model, source) = setUp("keymenu-answer", A.question(labels: ["Apple", "Banana"]))
        let menu = try #require(model.keyMenu)
        #expect(menu.answerCount == 3)
        model.handleKeyMenu(.digit(2))
        #expect(model.keyMenu == nil)
        #expect(model.answer.card == nil)   // sent: card closed at once
        for _ in 0..<50 where source.answersAttempted == 0 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(source.answersAttempted == 1)
        #expect(source.screenReads >= 1)   // the card's pre-send pane read
    }

    @Test func otherOpensTheCardTyping() throws {
        let (model, source) = setUp("keymenu-other", A.question(labels: ["Apple", "Banana"]))
        model.handleKeyMenu(.digit(3))
        let card = try #require(model.answer.card)
        #expect(card.state.phase == .typingOther)
        #expect(source.answersAttempted == 0)
    }

    @Test func multiSelectAnswerOpensTheCard() throws {
        let (model, source) = setUp("keymenu-multi", A.question(multi: true))
        let menu = try #require(model.keyMenu)
        #expect(menu.entries.first == .openCard(.answer))
        model.handleKeyMenu(.digit(1))
        #expect(model.answer.card != nil)
        #expect(source.answersAttempted == 0)
    }

    @Test func rendersMenuWithAnswerOptions() async throws {
        let question = A.question(title: "Deploy", question: "Ship it?",
                                  labels: ["Yes, push to the Pro now", "No — wait, and keep this branch local until the PO has looked at the render sheet tomorrow"])
        let (model, _) = setUp("keymenu-answer-render", question)
        let menu = try #require(model.keyMenu)
        await renderLightDark(RowKeyMenuView(menu: menu, agentLabel: "aptus-worker-fe", onChoose: { _ in }).padding(20),
                              size: CGSize(width: 400, height: 380), name: "keymenu-answers")
    }
}
