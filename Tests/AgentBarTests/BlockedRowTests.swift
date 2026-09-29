import Foundation
import Testing
@testable import AgentBar

/// What a Blocked row offers and where it sits: pure list logic.
struct BlockedRowTests {
    typealias A = AnswerFixtures
    typealias F = AgentListFixtures

    private func buttons(_ agent: AgentSnapshot) -> [RowButton] {
        RowButtons.available(for: agent).map(\.button)
    }

    // MARK: - Buttons

    @Test func aBlockedQuestionOffersAnswerThenPark() {
        #expect(buttons(A.blockedAgent("q", blocker: .question(A.question()))) == [.answer, .peek, .park])
    }

    @Test func aPermissionBoxOrAnUnparsedQuestionOffersOpenTerminalThenPark() {
        #expect(buttons(A.blockedAgent("p", blocker: .permission)) == [.openTerminal, .peek, .park])
        #expect(buttons(A.blockedAgent("u", blocker: .questionNotAnswerable)) == [.openTerminal, .peek, .park])
    }

    @Test func aQuestionStillLoadingShowsAReadingAnswerThatCannotBePressedYet() throws {
        let agent = A.blockedAgent("l", blocker: .questionLoading(nil))
        #expect(buttons(agent) == [.answer, .peek, .park])
        let answer = try #require(RowButtons.available(for: agent).first)
        #expect(!answer.isEnabled)
        #expect(answer.label == "Reading…")
        #expect(RowButtons.usableButtons(for: agent) == [.peek, .park])   // the keyboard skips it
    }

    @Test func onlyTheBlockedActionsAreRed() {
        #expect(RowButton.answer.isBlockedAction && RowButton.openTerminal.isBlockedAction)
        let others: [RowButton] = [.park, .unpark, .done, .closePane]
        #expect(others.allSatisfy { !$0.isBlockedAction })
    }

    @Test func aGenericNeedsYouRowKeepsDoneAndPark() {
        // Done moved into the ⋯ menu (RowButtonsTests covers its contents); the capsule strip is
        // Park, Message, then the ⋯ trigger.
        #expect(buttons(A.blockedAgent("g", blocker: nil)) == [.peek, .park, .message, .moreActions])
    }

    @Test func aParkedBlockedRowIsJustParked() {
        #expect(buttons(A.blockedAgent("k", blocker: .question(A.question()), section: .parked)) == [.unpark, .peek, .moreActions])
    }

    @Test func theKeyboardCanReachAnswerAndOpenTerminal() {
        #expect(RowButtons.usableButtons(for: A.blockedAgent("q", blocker: .question(A.question()))) == [.answer, .peek, .park])
        #expect(RowButtonHighlight.moved(from: nil, by: 1, in: [.answer, .park]) == .answer)
    }

    @Test func pressingAnswerOrOpenTerminalIsNeverASessionAction() {
        #expect(RowActionMachine.plan(pressing: .answer, current: nil) == .openAnswer)
        #expect(RowActionMachine.plan(pressing: .openTerminal, current: nil) == .openTerminal)
        #expect(RowButton.answer.sessionAction == nil)
        #expect(RowButton.openTerminal.sessionAction == nil)
    }

    // MARK: - Order

    @Test func blockedRowsSitAboveGenericNeedsYouRowsKeepingTheirOrderWithinEachGroup() {
        let question = AgentBlocker.question(A.question())
        let agents = [
            A.blockedAgent("finished1", blocker: nil),
            A.blockedAgent("permission", blocker: .permission),
            A.blockedAgent("finished2", blocker: nil),
            A.blockedAgent("question", blocker: question)
        ]
        let ordered = AgentRanking.ordered(agents, in: .needsYou, frecency: [:], now: F.now)
        #expect(ordered.map(\.id) == ["permission", "question", "finished1", "finished2"])
    }

    @Test func theListKeepsBlockedRowsInsideTheNeedsYouSection() {
        let snapshot = F.snapshot([
            A.blockedAgent("finished", blocker: nil),
            A.blockedAgent("question", blocker: .question(A.question())),
            F.agent("busy", section: .working)
        ])
        let rows = F.presentation(snapshot).rows
        #expect(rows.map(\.id) == ["section-0", "agent-question", "agent-finished", "section-1", "agent-busy"])
    }

    @Test func aParkedBlockedAgentLosesTheBlockedTreatment() {
        let parked = A.blockedAgent("q", blocker: .question(A.question())).placed(in: .parked)
        #expect(parked.blockedOnYou == nil)
    }

    // MARK: - Hints and layout

    @Test func footerHintsSpeakForTheAnswerCard() {
        typealias Hints = PanelFooterHints
        #expect(Hints.text(for: .init(answerMode: .singleSelect)) == "1-9 pick   ↑↓ move   ↩ send   ⌘C copy info   esc back")
        #expect(Hints.text(for: .init(answerMode: .multiSelect)).contains("space"))
        #expect(Hints.text(for: .init(answerMode: .multiSelect)).contains("submit"))
        #expect(Hints.text(for: .init(answerMode: .typing)) == "↩ send   ⇧↩ new line   ↑↓/esc back to options")
        #expect(Hints.text(for: .init(answerMode: .form)).contains("submit when all answered"))
        #expect(Hints.text(for: .init(answerMode: .formBusy)).contains("esc back when finished"))
        // The card outranks the list-level hints.
        #expect(!Hints.text(for: .init(hasHighlightedButton: true, answerMode: .singleSelect)).contains("button"))
    }

    @Test func theAnswerCardTakesTheFullListHeightSoItNeverClips() {
        let few = F.presentation(F.snapshot([F.agent("a")]))
        let full = AgentPanelMetrics.height(for: few, isAnswering: true)
        #expect(full == AgentPanelMetrics.height(for: few, isPeeking: true))
        #expect(full > AgentPanelMetrics.height(for: few))
        #expect(AgentPanelMetrics.fullBodyHeight() == AgentPanelMetrics.maxListHeight)
    }
}
