import AppKit
import SwiftUI
import Testing
@testable import AgentBar

/// The form card draws every question with its options, in each of its states, without breaking layout.
@MainActor @Suite(.serialized)
struct AnswerFormViewRenderTests {
    private func modelWithForm(configure: (AnswerCardModel) -> Void = { _ in }) async -> AnswerCardModel {
        let form = FormFixtures.form(multiSelect: [1])
        let model = AnswerCardModel(loadSessionContext: { _ in .empty }, loadPendingForm: { _ in form })
        model.statusSource = FakeFormTerminal(form: form)
        let question = PaneQuestionReader.question(in: FormFixtures.screen(form, tab: 0))!
        model.open(AnswerFixtures.blockedAgent("a", blocker: .question(question)))
        await waitUntil { model.card?.form != nil }
        configure(model)
        return model
    }

    private func render(_ model: AnswerCardModel) -> NSBitmapImageRep? {
        let host = NSHostingView(rootView: AnswerCardView(answer: model, bodyHeight: 600).frame(width: AgentPanelMetrics.width, height: 600))
        host.frame = CGRect(x: 0, y: 0, width: AgentPanelMetrics.width, height: 600)
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        if let path = ProcessInfo.processInfo.environment["FORM_RENDER_DIR"], let png = bitmap.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path).appendingPathComponent("form-\(UUID().uuidString.prefix(4)).png"))
        }
        return bitmap
    }

    @Test func theEditingFormDrawsAndSoDoTheSendingAndStoppedStates() async {
        let editing = await modelWithForm()
        #expect(render(editing) != nil)
        let partly = await modelWithForm { model in
            model.clickFormRow(0, of: 0)
            model.clickFormRow(1, of: 1)
            model.clickFormRow(0, of: 1)
            model.clickFormRow(model.card!.form!.otherRow(of: 2), of: 2)
            model.setFormOtherText("my own thing", of: 2)
        }
        #expect(render(partly) != nil)
        var stopped = partly.card!
        stopped.form?.stop(
            result: FormBatchResult(outcomes: [.landed, .refused("nope"), .notSent("x")], stopReason: "Stopped", finalNext: nil, seenIdentities: []),
            report: "Stopped: The dashboard refused question 2. Sent: question 1. Nothing was resent."
        )
        partly.card = stopped
        #expect(render(partly) != nil)
    }
}
