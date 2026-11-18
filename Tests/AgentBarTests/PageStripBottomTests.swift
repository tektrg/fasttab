import SwiftUI
import Testing
@testable import AgentBar

/// The page tabs moved from the top of the panel to just above the search box (2026-11-18).
/// The move must not change the window height budget; the render shows where they sit.
@MainActor @Suite(.serialized)
struct PageStripBottomTests {
    typealias F = AgentListFixtures

    @Test func stripAddsExactlyItsHeightWhereverItSits() {
        let p = F.presentation(F.snapshot([F.agent("a")]))
        let plain = AgentPanelMetrics.height(for: p)
        let withStrip = AgentPanelMetrics.height(for: p, showsPageStrip: true)
        #expect(withStrip - plain == AgentPanelMetrics.pageStripHeight)
    }

    @Test func rendersTabsAboveSearch() async {
        let defaults = makeScratchDefaults("tabs-bottom")
        let pages = AgentPagesModel(store: AgentSavedViewStore(defaults: defaults))
        pages.store.add(AgentSavedView(name: "Workers"))
        pages.store.add(AgentSavedView(name: "Chiefs"))
        let model = AgentPanelModel(
            store: FrecencyStore(defaults: defaults), triageStore: TriageStore(defaults: defaults),
            answer: AnswerCardModel(loadSessionContext: { _ in .empty }, openFile: { _ in }),
            permission: PermissionCardModel(loadSessionContext: { _ in .empty }),
            pages: pages, now: { F.now }
        )
        model.receive(F.snapshot([F.agent("a", label: "aptus-worker-fe"), F.agent("b", label: "chief-ops")]))
        #expect(model.showsPageStrip)
        let view = AgentPanelView(model: model, onClose: {}, onOpenSettings: {})
        await renderLightDark(view, size: CGSize(width: AgentPanelMetrics.width, height: 420), name: "tabs-bottom")
    }
}
