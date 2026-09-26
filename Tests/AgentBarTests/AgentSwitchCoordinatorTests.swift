import Foundation
import Testing
import CommandBarKit
@testable import AgentBar

@MainActor
struct AgentSwitchCoordinatorTests {
    typealias F = AgentListFixtures

    private final class FakeStatusSource: AgentStatusSource, @unchecked Sendable {
        let updates = AsyncStream<StatusSnapshot> { _ in }
        var focusResult = FocusResult.success
        private(set) var focusedPaneIds: [String] = []
        func focus(paneId: String) async -> FocusResult {
            focusedPaneIds.append(paneId)
            return focusResult
        }
        func paneScreen(paneId: String) async -> PaneScreenResult { .failure("unused") }
        func answer(paneId: String, choice: AnswerChoice, question: QuestionIdentity) async -> AnswerResult { .failed("unused") }
        func perform(_ kind: SessionActionKind, rowId: String, confirmed: Bool) async -> SessionActionOutcome { .failed("unused") }
    }

    @MainActor private final class PanelSpy {
        var isVisible = true
        var events: [String] = []
        var controls: AgentSwitchCoordinator.PanelControls {
            .init(
                hide: { self.isVisible = false; self.events.append("hide") },
                show: { self.isVisible = true; self.events.append("show") },
                isVisible: { self.isVisible }
            )
        }
    }

    private struct Rig {
        let model: AgentPanelModel
        let source: FakeStatusSource
        let panel: PanelSpy
        let coordinator: AgentSwitchCoordinator
    }

    private let snapshot = F.snapshot([
        F.agent("a", section: .needsYou),
        F.agent("b", section: .working)
    ])

    private func makeRig() -> Rig {
        let suite = "AgentBarTests.\(UUID().uuidString)"
        let store = FrecencyStore(defaults: UserDefaults(suiteName: suite)!)
        let model = AgentPanelModel(store: store, now: { F.now })
        model.receive(snapshot)
        let source = FakeStatusSource()
        let panel = PanelSpy()
        return Rig(model: model, source: source, panel: panel,
                   coordinator: AgentSwitchCoordinator(model: model, statusSource: source, panel: panel.controls))
    }

    @Test func successClosesThePanelFocusesThePaneAndRecordsTheSwitch() async {
        let rig = makeRig()
        await rig.coordinator.switchTo(F.agent("b", section: .working))
        #expect(rig.panel.events == ["hide"])
        #expect(rig.source.focusedPaneIds == ["w1:b"])
        #expect(rig.model.footerNotice == nil)
    }

    @Test func aSuccessfulSwitchReRanksTheAgent() async {
        let rig = makeRig()
        rig.model.receive(F.snapshot([
            F.agent("w1", section: .working), F.agent("w2", section: .working)
        ]))
        await rig.coordinator.switchTo(F.agent("w2", section: .working))
        #expect(rig.model.presentation.agents.map(\.id) == ["w2", "w1"])
    }

    @Test func failureClosesThenReopensWithAReadableMessageAndDoesNotRankIt() async {
        let rig = makeRig()
        rig.model.receive(F.snapshot([
            F.agent("w1", section: .working), F.agent("w2", section: .working)
        ]))
        rig.source.focusResult = .failure("pane w1:w2 not found — likely closed")
        await rig.coordinator.switchTo(F.agent("w2", section: .working))
        #expect(rig.panel.events == ["hide", "show"])
        #expect(rig.model.footerNotice == .switchFailed("pane w1:w2 not found — likely closed"))
        #expect(rig.model.footerNotice?.text == "Couldn't switch: pane w1:w2 not found — likely closed")
        #expect(rig.model.presentation.agents.map(\.id) == ["w1", "w2"])   // unchanged order
    }

    @Test func failureLeavesAnAlreadyReopenedPanelAlone() async {
        let rig = makeRig()
        rig.source.focusResult = .failure("boom")
        // The user reopened the panel during the round trip.
        let hide = rig.panel.controls.hide
        let controls = AgentSwitchCoordinator.PanelControls(
            hide: { hide(); rig.panel.isVisible = true }, show: rig.panel.controls.show, isVisible: rig.panel.controls.isVisible)
        let coordinator = AgentSwitchCoordinator(model: rig.model, statusSource: rig.source, panel: controls)
        await coordinator.switchTo(F.agent("b", section: .working))
        #expect(rig.panel.events == ["hide"])
        #expect(rig.model.footerNotice == .switchFailed("boom"))
    }

    @Test func anAgentWithoutAPaneNeverCallsTheSource() async {
        let rig = makeRig()
        let paneless = AgentSnapshot(
            id: "x", label: "x", projectName: nil, cwd: nil, paneId: nil, section: .needsYou, statusText: "",
            secondsInStatus: nil, hasUnpushedCommits: false, unpushedText: nil, promptExcerpt: nil,
            canFocus: true, hasHookData: true)
        await rig.coordinator.switchTo(paneless)
        #expect(rig.source.focusedPaneIds.isEmpty)
        #expect(rig.model.footerNotice != nil)
    }

    // MARK: - Status-only rows (Claude Desktop / CLI outside herdr)

    @MainActor private final class DesktopOpenerSpy: ClaudeDesktopOpening {
        var opens = true
        private(set) var openedURLs: [URL?] = []
        func openSession(_ url: URL?) -> Bool {
            openedURLs.append(url)
            return opens
        }
    }

    private func coordinator(_ rig: Rig, opener: DesktopOpenerSpy) -> AgentSwitchCoordinator {
        AgentSwitchCoordinator(model: rig.model, statusSource: rig.source, panel: rig.panel.controls, desktopOpener: opener)
    }

    @Test func aDesktopSessionOpensInClaudeAppAndNeverAsksTheDashboardToFocus() async {
        let rig = makeRig()
        let opener = DesktopOpenerSpy()
        let desktop = StatusOnlyFixtures.desktopAgent("d")
        rig.model.receive(F.snapshot([F.agent("w1", section: .working), desktop]))
        await coordinator(rig, opener: opener).switchTo(desktop)
        #expect(opener.openedURLs == [URL(string: StatusOnlyFixtures.openUrl)])
        #expect(rig.source.focusedPaneIds.isEmpty)
        #expect(rig.panel.events == ["hide"])
        #expect(rig.model.footerNotice == nil)
    }

    @Test func aDesktopSessionThatCannotOpenSaysSo() async {
        let rig = makeRig()
        let opener = DesktopOpenerSpy()
        opener.opens = false
        await coordinator(rig, opener: opener).switchTo(StatusOnlyFixtures.desktopAgent("d"))
        #expect(rig.panel.events == ["hide", "show"])
        #expect(rig.model.footerNotice == .switchFailed("Claude Desktop could not be opened."))
        #expect(rig.source.focusedPaneIds.isEmpty)
    }

    @Test func aCliSessionOutsideHerdrKeepsThePanelAndSaysWhereItRuns() async {
        let rig = makeRig()
        let opener = DesktopOpenerSpy()
        let cli = AgentSnapshot(
            id: "c", label: "c", projectName: nil, cwd: nil, paneId: nil, section: .needsYou, statusText: "",
            secondsInStatus: nil, hasUnpushedCommits: false, unpushedText: nil, promptExcerpt: nil,
            canFocus: true, hasHookData: true, host: .claudeCLI(tmuxTarget: "work:@3.%7"))
        await coordinator(rig, opener: opener).switchTo(cli)
        #expect(rig.panel.events.isEmpty)
        #expect(opener.openedURLs.isEmpty)
        #expect(rig.source.focusedPaneIds.isEmpty)
        #expect(rig.model.footerNotice == .switchFailed(AgentSwitchCoordinator.cliSessionMessage(tmuxTarget: "work:@3.%7")))
        #expect(AgentSwitchCoordinator.cliSessionMessage(tmuxTarget: "work:@3.%7").contains("tmux (work:@3.%7)"))
    }
}
