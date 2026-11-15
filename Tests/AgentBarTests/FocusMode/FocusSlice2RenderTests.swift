import AppKit
import SwiftUI
import Testing
@testable import AgentBar

/// Focus mode slice 2, whole overlay drawn offscreen in light and dark: the header's Go to button, the
/// big plan box, the waiting-agent Message card, and a disabled "Runs on Air" home. Set `FOCUS_RENDER_DIR`
/// to keep the PNGs (`focus-<name>-<light|dark>.png`).
@MainActor @Suite(.serialized)
struct FocusSlice2RenderTests {
    typealias A = AnswerFixtures
    typealias F = AgentListFixtures

    private func makeModel(screen: [String]? = nil) -> AgentPanelModel {
        let defaults = makeScratchDefaults("focus-s2-render")
        let model = AgentPanelModel(
            store: FrecencyStore(defaults: defaults),
            triageStore: TriageStore(defaults: defaults),
            answer: AnswerCardModel(loadSessionContext: { _ in .empty }, openFile: { _ in }),
            permission: PermissionCardModel(
                loadSessionContext: { _ in .empty },
                loadPlanFile: { _ in .text(Self.planText, truncated: false) }
            ),
            now: { F.now }
        )
        let source = PermissionFakeSource()
        source.screen = .screen(lines: screen ?? PermissionFixtures.screen(for: PermissionFixtures.bash), readAt: F.now)
        model.statusSource = source
        return model
    }

    nonisolated static let planText = """
    # Focus mode slice 2

    1. **Go to agent** — header button labelled by host; Focus pauses on a jump, ⌥⇧F resumes.
    2. **Plan polish** — large plan box, large Message card, "Answered elsewhere" toast.
    3. Keep light and dark working.

    ## Risks
    - The overlay must hide before the agent's app comes forward.
    - Drafts survive only while the main panel stays closed.
    """

    private func render(_ session: FocusSession, name: String) async {
        for dark in [false, true] {
            let size = CGSize(width: 1512, height: 900)
            let view = FocusOverlayView(session: session, reduceMotion: true, onExit: {}, startsAppeared: true)
                .frame(width: size.width, height: size.height)
                .background(dark ? Color(white: 0.15) : Color(white: 0.85))
                .environment(\.colorScheme, dark ? .dark : .light)
            let host = NSHostingView(rootView: view)
            host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            host.frame = CGRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(600))
            host.layoutSubtreeIfNeeded()
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                Issue.record("no bitmap"); return
            }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            if let dir = ProcessInfo.processInfo.environment["FOCUS_RENDER_DIR"], let png = bitmap.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("focus-\(name)-\(dark ? "dark" : "light").png"))
            }
        }
    }

    @Test func planBoxWithGoTo() async {
        let model = makeModel(screen: PlanFixtures.screen(for: PlanFixtures.box))
        model.receive(F.snapshot([PlanFixtures.agent("p"), A.blockedAgent("q", blocker: .question(A.question()))]))
        let session = FocusSession(model: model, loadContext: { _ in FocusContext(lastMessage: "The plan is ready for review.", hasTranscript: true) })
        await waitUntil { model.permission.card?.plan?.phase == .ready && model.permission.card?.planFile != .loading }
        #expect(model.permission.card?.plan != nil)
        await render(session, name: "plan")
    }

    @Test func waitingAgentMessageCard() async {
        let model = makeModel()
        model.receive(F.snapshot([A.blockedAgent("w", blocker: nil)]))
        let session = FocusSession(model: model, loadContext: { _ in FocusContext(lastMessage: "Done. Tests pass; want me to push?", hasTranscript: true) })
        await waitUntil { session.contexts["w"] != nil }
        #expect(session.ask == .message)
        await render(session, name: "message")
    }

    @Test func airAgentGoToDisabled() async {
        let model = makeModel()
        model.receive(F.snapshot([A.blockedAgent("air", blocker: .questionNotAnswerable, paneId: "air-m1:w2:p1")]))
        let session = FocusSession(model: model, loadContext: { _ in FocusContext(lastMessage: nil, hasTranscript: false) })
        #expect(session.destination?.isEnabled == false)
        await render(session, name: "air")
    }

    @Test func singleQuestionTypedOtherIsLarge() async {
        let model = makeModel()
        model.receive(F.snapshot([A.blockedAgent("q", blocker: .question(A.question()))]))
        let session = FocusSession(model: model, loadContext: { _ in FocusContext(lastMessage: nil, hasTranscript: false) })
        if let other = model.answer.card?.state.question.options.firstIndex(where: \.isOther) {
            model.answer.clickOption(at: other)
            model.answer.setOtherText("Use the staging build instead")
        }
        await render(session, name: "other")
    }
}
