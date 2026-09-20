import Foundation
import Testing
@testable import AgentBar

/// The message card as the panel drives it: the row button, keys, the row's own words, and the footer.
@MainActor
struct MessagePanelModelTests {
    typealias F = AgentListFixtures

    private final class Clock { var now = F.now }

    private struct Rig {
        let model: AgentPanelModel
        let source: MessageFakeSource
        let clock: Clock
    }

    private func makeRig(_ agents: [AgentSnapshot]) -> Rig {
        let defaults = makeScratchDefaults("message-panel")
        let clock = Clock()
        let model = AgentPanelModel(
            store: FrecencyStore(defaults: defaults),
            triageStore: TriageStore(defaults: defaults),
            answer: AnswerCardModel(loadSessionContext: { _ in .empty }, openFile: { _ in }),
            permission: PermissionCardModel(now: { clock.now }, loadSessionContext: { _ in .empty }),
            message: MessageCardModel(now: { clock.now }, loadSessionContext: { _ in .empty }),
            now: { clock.now }
        )
        let source = MessageFakeSource()
        model.statusSource = source
        model.receive(F.snapshot(agents))
        return Rig(model: model, source: source, clock: clock)
    }

    private func working(_ id: String = "w") -> AgentSnapshot { F.agent(id, section: .working) }

    @Test func pressingMessageOpensTheCardInPlaceOfTheList() {
        let rig = makeRig([working()])
        rig.model.press(.message, on: "w")
        #expect(rig.model.message.card?.agentID == "w")
        #expect(rig.model.isCardOpen)
        #expect(rig.model.selectedAgentID == "w")
    }

    @Test func theKeyboardReachesMessageWithRightThenEnter() {
        let rig = makeRig([working()])
        rig.model.moveButtonHighlight(by: 1)
        #expect(rig.model.highlightedButton == .message)
        rig.model.activateSelected()
        #expect(rig.model.message.isOpen)
    }

    @Test func aBlockedRowsButtonsAreUntouchedAndMessageCannotBePressedOnIt() {
        var blocked = F.agent("b", section: .needsYou)
        blocked.blocker = .permission
        let rig = makeRig([blocked])
        #expect(rig.model.press(.message, on: "b") == nil)
        #expect(!rig.model.message.isOpen)
    }

    @Test func openingMessageClosesOtherCardsAndTheOtherWayRound() {
        let question = AnswerFixtures.blockedAgent("q", blocker: .question(AnswerFixtures.question()))
        let rig = makeRig([question, working()])
        rig.model.press(.answer, on: "q")
        #expect(rig.model.answer.isOpen)
        rig.model.press(.message, on: "w")
        #expect(rig.model.message.isOpen && !rig.model.answer.isOpen)
        rig.model.press(.answer, on: "q")
        #expect(rig.model.answer.isOpen && !rig.model.message.isOpen)
    }

    @Test func escapeBacksOutOfTheCardAndReturnDoesNotSwitchToTheAgent() async {
        let rig = makeRig([working()])
        var activated = 0
        rig.model.onActivate = { _ in activated += 1 }
        rig.model.press(.message, on: "w")
        rig.model.message.setDraft("hello")
        rig.model.activateSelected()   // Return in the search box sends, not switches
        await rig.source.waitForRequests(1)
        #expect(activated == 0)
        rig.source.reply(.failed("nope"))
        await waitUntil { rig.model.message.card?.phase == .editing }
        #expect(rig.model.backOutOfButtons())
        #expect(!rig.model.message.isOpen)
    }

    @Test func arrowsAndSpaceDoNothingWhileTheCardIsOpen() {
        let rig = makeRig([working("a"), working("b")])
        rig.model.press(.message, on: "a")
        rig.model.moveSelectionOrAnswerHighlight(by: 1)
        #expect(rig.model.selectedAgentID == "a")
        #expect(rig.model.message.isOpen)
        #expect(rig.model.moveButtonHighlight(by: 1))
        #expect(rig.model.highlightedButton == nil)
        #expect(rig.model.togglePeek())
        #expect(rig.model.peek == nil)
    }

    @Test func aSuccessfulSendShowsMessageSentOnTheRowInPlaceOfItsButtons() async {
        let rig = makeRig([working()])
        rig.model.press(.message, on: "w")
        rig.model.message.setDraft("hello")
        rig.model.activateSelected()
        await rig.source.waitForRequests(1)
        let agent = rig.model.presentation.agents[0]
        #expect(rig.model.sendingLabel(for: agent) == "Sending message…")
        rig.source.reply(.sent(queued: false))
        await waitUntil { rig.model.sentLabel(for: agent) != nil }
        #expect(rig.model.sentLabel(for: agent) == "Message sent")
        #expect(!rig.model.message.isOpen)
        rig.model.moveButtonHighlight(by: 1)
        #expect(rig.model.highlightedButton == nil)   // no buttons while the label shows
        #expect(rig.model.press(.message, on: "w") == nil && !rig.model.message.isOpen)
        rig.clock.now = rig.clock.now.addingTimeInterval(7)
        #expect(rig.model.sentLabel(for: agent) == nil)
        rig.model.press(.message, on: "w")
        #expect(rig.model.message.isOpen)
    }

    @Test func cmdCCopiesTheOpenMessageCardsAgent() {
        let rig = makeRig([working()])
        rig.model.press(.message, on: "w")
        #expect(rig.model.copyOpenCardIdentity())
        #expect(rig.model.copier.copiedAgentID == "w")
    }

    @Test func aFailureAfterTheCardWentAwayReachesTheFooterNotice() async {
        let rig = makeRig([working()])
        rig.model.press(.message, on: "w")
        rig.model.message.setDraft("hello")
        rig.model.activateSelected()
        await rig.source.waitForRequests(1)
        rig.model.resetForShow()   // the panel was dismissed and summoned again
        rig.source.reply(.failed("NOT SUBMITTED"))
        await waitUntil { rig.model.footerNotice != nil }
        #expect(rig.model.footerNotice?.isDismissible == true)
    }

    @Test func showingThePanelAgainClosesTheCardAndDropsTheDraft() {
        let rig = makeRig([working()])
        rig.model.press(.message, on: "w")
        rig.model.message.setDraft("half a thought")
        rig.model.resetForShow()
        #expect(!rig.model.message.isOpen)
    }

    @Test func theFooterHintsFollowTheCard() {
        var context = PanelFooterHints.Context()
        context.messageMode = .composing
        #expect(PanelFooterHints.text(for: context) == "↩ send   esc back")
        context.messageMode = .confirming
        #expect(PanelFooterHints.text(for: context).contains("send anyway"))
    }
}
