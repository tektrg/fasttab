import AppKit
import SwiftUI
import Testing
@testable import AgentBar

/// Draws a view offscreen in light and dark. Set `FOCUS_RENDER_DIR` to keep the PNGs (`<name>-<light|dark>.png`).
@MainActor
func renderLightDark<V: View>(_ view: V, size: CGSize, name: String) async {
    for dark in [false, true] {
        let root = view
            .frame(width: size.width, height: size.height)
            .background(dark ? Color(white: 0.15) : Color(white: 0.92))
            .environment(\.colorScheme, dark ? .dark : .light)
        let host = NSHostingView(rootView: root)
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(600))
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { Issue.record("no bitmap"); return }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        if let dir = ProcessInfo.processInfo.environment["FOCUS_RENDER_DIR"], let png = bitmap.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
        }
    }
}

@MainActor @Suite(.serialized)
struct ActionRowRenderTests {
    typealias A = AnswerFixtures
    typealias F = AgentListFixtures

    private func makeModel() -> AgentPanelModel {
        let defaults = makeScratchDefaults("action-row-render")
        let model = AgentPanelModel(
            store: FrecencyStore(defaults: defaults),
            triageStore: TriageStore(defaults: defaults),
            answer: AnswerCardModel(loadSessionContext: { _ in .empty }, openFile: { _ in }),
            permission: PermissionCardModel(loadSessionContext: { _ in .empty }),
            now: { F.now }
        )
        let source = PermissionFakeSource()
        source.screen = .screen(lines: ["$ swift test", "All tests passed."], readAt: F.now)
        model.statusSource = source
        return model
    }

    @Test(arguments: [1512.0, 980.0])
    func focusCardWithActionRow(width: Double) async {
        let model = makeModel()
        model.receive(F.snapshot([A.blockedAgent("q", blocker: .question(A.question())), A.blockedAgent("w", blocker: nil)]))
        let session = FocusSession(model: model, loadContext: { _ in FocusContext(lastMessage: "Which build should I ship?", hasTranscript: true) })
        let view = FocusOverlayView(session: session, reduceMotion: true, onExit: {}, startsAppeared: true)
        await renderLightDark(view, size: CGSize(width: width, height: 820), name: "action-focus-\(Int(width))")
    }

    @Test(arguments: [640.0, 300.0])
    func actionRowAloneOverflowsIntoMore(width: Double) async {
        let items = AgentActionList.items(for: F.agent("idle"), tree: nil)
        let view = AgentActionRow(items: items, onAction: { _ in }).padding(12)
        await renderLightDark(view, size: CGSize(width: width, height: 56), name: "action-row-\(Int(width))")
    }
}
