import Foundation
import Testing
@testable import AgentBar

/// The card end to end when the terminal moves past the form on its own (the dashboard, or the user, submitted it):
/// the agent's transcript is asked what was recorded, and the report says so instead of "not attempted".
@MainActor
struct FormRecordedAnswersCardTests {
    private let form = FormFixtures.form()

    private func rig(recorded: RecordedFormAnswers?) -> (model: AnswerCardModel, source: ScriptedFormSource, agent: AgentSnapshot, notices: NoticeLog) {
        var timing = FormBatchTiming()
        timing.pause = { _ in }
        let model = AnswerCardModel(
            loadSessionContext: { _ in .empty }, loadPendingForm: { [form] _ in form },
            loadRecordedAnswers: { _, _ in recorded }, formTiming: timing
        )
        let source = ScriptedFormSource(screens: [FormFixtures.screen(form, tab: 0), FormFixtures.reviewScreen(form)])
        let notices = NoticeLog()
        model.statusSource = source
        model.onNotice = { notices.lines.append($0) }
        let question = PaneQuestionReader.question(in: FormFixtures.screen(form, tab: 0))!
        return (model, source, AnswerFixtures.blockedAgent("a", blocker: .question(question), sessionId: "session-1"), notices)
    }

    final class NoticeLog { var lines: [String] = [] }

    @Test func aFormSubmittedElsewhereIsReportedFromTheTranscriptAndFlagsWhatDiffers() async {
        // The user picked option 1, 2, 1; the record says question 2 got option 1 instead of option 2.
        let recorded = RecordedFormAnswers(answers: [0: "Just clear it (Recommended)", 1: "Back to Needs you (Recommended)", 2: "Yes, for Needs you (Recommended)"])
        let rig = rig(recorded: recorded)
        #expect(rig.model.open(rig.agent))
        await waitUntil { rig.model.card?.form != nil }
        rig.model.clickFormRow(0, of: 0)
        rig.model.clickFormRow(1, of: 1)
        rig.model.clickFormRow(0, of: 2)
        rig.model.pressSend()
        await waitUntil { rig.model.card?.form?.sendState == .stopped }
        let report = rig.model.card?.form?.report ?? ""
        #expect(report.hasPrefix("The form was submitted."))
        #expect(report.contains("You chose \"Done returns, Parked stays\" but the terminal recorded \"Back to Needs you (Recommended)\""))
        #expect(!report.contains("Not attempted"))
        #expect(rig.source.sent.count == 1)
        #expect(rig.notices.lines == [report])
    }
}
