import Foundation
import Testing
@testable import AgentBar

/// `AgentPanelModel.openCardForCorner`/`closeCardOpenedForCorner`: what the corner tab calls when
/// it decides to show the sole blocked agent's live card in place of the pill. These reuse the
/// exact same `answer`/`permission` the row's Answer/Review press would open (`AnswerPanelModelTests`/
/// `PermissionPanelModelTests` cover what happens once a card is open); these tests only cover the
/// routing: the right card opens for the right blocker, a second call for the same agent never
/// resets it, and closing tears down whichever one is open.
@MainActor
struct CornerCardOpeningTests {
    typealias A = AnswerFixtures
    typealias P = PermissionFixtures
    typealias F = AgentListFixtures

    private func makeRig(_ agents: [AgentSnapshot]) -> (model: AgentPanelModel, source: PermissionFakeSource) {
        let defaults = makeScratchDefaults("corner-card")
        let model = AgentPanelModel(
            store: FrecencyStore(defaults: defaults),
            triageStore: TriageStore(defaults: defaults),
            answer: AnswerCardModel(loadSessionContext: { _ in .empty }, openFile: { _ in }),
            permission: PermissionCardModel(loadSessionContext: { _ in .empty }),
            now: { F.now }
        )
        let source = PermissionFakeSource()
        source.screen = .screen(lines: P.screen(for: P.bash), readAt: F.now)
        model.statusSource = source
        model.receive(F.snapshot(agents))
        return (model, source)
    }

    private var fruit: AnswerableQuestion { A.question() }

    // MARK: - Opens the right card

    @Test func aQuestionBlockerOpensTheAnswerCard() {
        let (model, _) = makeRig([A.blockedAgent("q", blocker: .question(fruit))])
        model.openCardForCorner(agentID: "q")
        #expect(model.answer.card?.agentID == "q")
        #expect(!model.permission.isOpen)
    }

    @Test func aPermissionReviewBlockerOpensThePermissionCard() async {
        let (model, _) = makeRig([P.agent("p", P.bash)])
        model.openCardForCorner(agentID: "p")
        await waitUntil { model.permission.card?.agentID == "p" }
        #expect(!model.answer.isOpen)
    }

    @Test func anUnknownAgentIDOpensNothing() {
        let (model, _) = makeRig([A.blockedAgent("q", blocker: .question(fruit))])
        model.openCardForCorner(agentID: "missing")
        #expect(!model.answer.isOpen)
        #expect(!model.permission.isOpen)
    }

    @Test func aBlockerWithNoCardOpensNothing() {
        for blocker in [AgentBlocker.questionLoading(nil), .questionNotAnswerable, .permission] {
            let (model, _) = makeRig([A.blockedAgent("x", blocker: blocker)])
            model.openCardForCorner(agentID: "x")
            #expect(!model.answer.isOpen, "\(blocker)")
            #expect(!model.permission.isOpen, "\(blocker)")
        }
    }

    @Test func theReturnValueSaysWhetherThereIsACardToShow() {
        let (model, _) = makeRig([A.blockedAgent("q", blocker: .question(fruit)), A.blockedAgent("x", blocker: .permission)])
        #expect(model.openCardForCorner(agentID: "q"))
        #expect(model.openCardForCorner(agentID: "q"))   // already open: still a card to show
        #expect(!model.openCardForCorner(agentID: "x"))
        #expect(!model.openCardForCorner(agentID: "missing"))
    }

    @Test func aLeftoverSearchDoesNotHideTheBlockedAgent() {
        let (model, _) = makeRig([A.blockedAgent("q", blocker: .question(fruit))])
        model.query = "no-such-agent-text"
        #expect(model.openCardForCorner(agentID: "q"))
        #expect(model.answer.card?.agentID == "q")
    }

    // MARK: - A repeat call for the same agent never resets it

    @Test func aSecondCallForTheSameQuestionKeepsTheTypedDraft() {
        let (model, _) = makeRig([A.blockedAgent("q", blocker: .question(fruit))])
        model.openCardForCorner(agentID: "q")
        let otherPosition = model.answer.card!.state.question.options.count - 1
        model.answer.clickOption(at: otherPosition)
        model.answer.setOtherText("draft answer")
        model.openCardForCorner(agentID: "q")
        #expect(model.answer.card?.state.phase == .typingOther)
        #expect(model.answer.card?.state.otherText == "draft answer")
    }

    @Test func aSecondCallForTheSamePermissionKeepsTheHighlight() async {
        let (model, _) = makeRig([P.agent("p", P.bash)])
        model.openCardForCorner(agentID: "p")
        await waitUntil { model.permission.card?.state.phase == .ready }
        model.permission.clickChoice(.allow)
        model.openCardForCorner(agentID: "p")
        #expect(model.permission.card?.state.highlighted == .allow)
    }

    // MARK: - Closing

    @Test func closingTearsDownAnOpenAnswerCard() {
        let (model, _) = makeRig([A.blockedAgent("q", blocker: .question(fruit))])
        model.openCardForCorner(agentID: "q")
        model.closeCardOpenedForCorner()
        #expect(!model.answer.isOpen)
    }

    @Test func closingTearsDownAnOpenPermissionCard() async {
        let (model, _) = makeRig([P.agent("p", P.bash)])
        model.openCardForCorner(agentID: "p")
        await waitUntil { model.permission.isOpen }
        model.closeCardOpenedForCorner()
        #expect(!model.permission.isOpen)
    }

    @Test func closingWithNothingOpenDoesNothing() {
        let (model, _) = makeRig([A.blockedAgent("q", blocker: .question(fruit))])
        model.closeCardOpenedForCorner()
        #expect(!model.answer.isOpen)
        #expect(!model.permission.isOpen)
    }
}
