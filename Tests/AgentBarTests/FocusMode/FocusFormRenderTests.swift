import AppKit
import SwiftUI
import Testing
@testable import AgentBar

/// Focus mode's right panel draws a multi-question form in large type. Set `FOCUS_RENDER_DIR` to keep the PNG
/// (dark, the right column's size on a 1512pt-wide screen).
@MainActor @Suite(.serialized)
struct FocusFormRenderTests {
    @Test func theFormDrawsLarge() {
        let defaults = makeScratchDefaults("focus-form-render")
        let model = AgentPanelModel(
            store: FrecencyStore(defaults: defaults),
            triageStore: TriageStore(defaults: defaults),
            answer: AnswerCardModel(loadSessionContext: { _ in .empty }, openFile: { _ in }),
            permission: PermissionCardModel(loadSessionContext: { _ in .empty }),
            now: { AgentListFixtures.now }
        )
        let source = PermissionFakeSource()
        source.screen = .screen(lines: PermissionFixtures.screen(for: PermissionFixtures.bash), readAt: AgentListFixtures.now)
        model.statusSource = source
        model.receive(AgentListFixtures.snapshot([AnswerFixtures.blockedAgent("q", blocker: .question(AnswerFixtures.question()))]))
        let session = FocusSession(model: model, loadContext: { _ in FocusContext(lastMessage: nil, hasTranscript: false) })
        let form = PendingQuestionForm(toolUseId: "t", questions: [
            FormQuestion(header: "3 app bugs", question: "Three likely app bugs were found in the v1.2 release candidate: (22) after a completed make-up workout, Home still says 'You missed Fri'; (33) closing a day you only marked complete asks 'Discard changes?'; (38) after deleting a workout, the Progress summary card collapses. None has been fixed. How should v1.2 handle them?", isMultiSelect: false, options: [
                .init(label: "Fix all 3 before v1.2 (Recommended)", description: "Run each through the normal fix-and-prove process on release/v1.2.0. Delays v1.2 by roughly a day."),
                .init(label: "Fix 33 + 38, defer 22", description: "Fix the two with a likely cause. The banner bug (22) ships as a known issue."),
                .init(label: "Ship v1.2, fix in v1.2.1", description: "Release now with all 3 as known issues, then fix them in a quick follow-up."),
            ]),
            FormQuestion(header: "PR #292", question: "Pull request #292 updates 5 outdated sync tests, which now pass; test 07 still fails. Merge #292 now?", isMultiSelect: false, options: [
                .init(label: "Merge now, fix 07 after (Recommended)", description: "The 5 proven fixes land now; 07 gets a separate small fix."),
                .init(label: "Wait for 07", description: "Keep #292 open until 07 passes too, then merge once."),
            ]),
        ])
        model.answer.card?.form = AnswerFormState(form: form)
        model.answer.clickFormRow(0, of: 0)
        #expect(session.handleFormKey(.move(1)))
        let size = CGSize(width: 860, height: 900)
        let view = FocusAskView(session: session).padding(28).frame(width: size.width, height: size.height)
            .background(FocusPalette.card).environment(\.colorScheme, .dark)
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        host.layoutSubtreeIfNeeded()
        let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)
        #expect(bitmap != nil)
        if let bitmap {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            if let dir = ProcessInfo.processInfo.environment["FOCUS_RENDER_DIR"], let png = bitmap.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("focus-form.png"))
            }
        }
    }
}
