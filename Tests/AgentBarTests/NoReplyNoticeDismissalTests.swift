import Foundation
import Testing
@testable import AgentBar

/// The "No reply from the dashboard…" notice (a send that got no answer in time) is a
/// failure notice like any other: it must close on ✕ / esc and stay closed.
@MainActor
struct NoReplyNoticeDismissalTests {
    typealias A = AnswerFixtures
    typealias F = AgentListFixtures

    private let fruit = A.question()

    private func makeRigWithExpiredSend() async -> (model: AgentPanelModel, agent: AgentSnapshot) {
        let defaults = makeScratchDefaults("no-reply-notice")
        let answer = AnswerCardModel(sendExpirySeconds: 0.05, loadSessionContext: { _ in .empty }, openFile: { _ in })
        let model = AgentPanelModel(
            store: FrecencyStore(defaults: defaults), triageStore: TriageStore(defaults: defaults),
            answer: answer, now: { F.now }
        )
        let source = AnswerFakeSource()   // never replies
        model.statusSource = source
        let agent = A.blockedAgent("q", blocker: .question(fruit))
        model.receive(F.snapshot([agent]))
        model.press(.answer, on: "q")
        model.answer.handle(.digit(1))
        await source.waitForRequests(1)
        await waitUntil { model.footerNotice != nil }
        return (model, agent)
    }

    @Test func theNoReplyNoticeIsADismissibleFailureAndStaysClosed() async {
        let (model, agent) = await makeRigWithExpiredSend()
        #expect(model.footerNotice == .actionFailed(AnswerCardModel.noReplyMessage))
        #expect(model.footerNotice?.isDismissible == true)
        #expect(model.dismissFooterNotice())
        #expect(model.footerNotice == nil)
        model.receive(F.snapshot([agent]))   // later status updates do not bring it back
        await settleTasks()
        #expect(model.footerNotice == nil)
    }

    @Test func escInsideTheAnswerCardTextFieldClosesTheNoticeBeforeLeavingTheField() async {
        let (model, _) = await makeRigWithExpiredSend()
        model.press(.answer, on: "q")   // the send expired, so the row can be answered again
        #expect(model.answer.isOpen)
        model.answer.handle(.escape)    // what the multi-line field calls on esc
        #expect(model.footerNotice == nil)
        #expect(model.answer.isOpen)    // the notice took the esc; the card stays
    }
}
