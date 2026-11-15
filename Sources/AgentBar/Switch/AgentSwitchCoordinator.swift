import Foundation
import IndieAgentSessions

/// Switching to an agent: close the panel at once, ask the status source to
/// focus the agent's terminal tab, then settle the outcome.
///
/// - Success: the switch is recorded for ranking (frecency).
/// - Failure: the switch is NOT recorded (a dead pane must not float to the
///   top), and the panel comes back with a red "Couldn't switch: ..." notice that
///   stays until the user closes it, since by then their eyes are already elsewhere.
///   If the panel was reopened in the meantime it is left as is and only gets the notice.
/// - Status-only rows (`AgentHost`) never reach the dashboard's focus: a Claude Desktop session
///   opens in Claude.app (`ClaudeDesktopOpening`); a Claude CLI session in tmux is brought
///   forward by `TmuxSessionSwitching`; one with no tmux target has nothing to switch to, so the
///   panel stays and says so.
@MainActor
final class AgentSwitchCoordinator {
    struct PanelControls {
        var hide: @MainActor () -> Void
        var show: @MainActor () -> Void
        var isVisible: @MainActor () -> Bool
    }

    private let model: AgentPanelModel
    /// Replaced when the user points AgentBar at another dashboard.
    var statusSource: any AgentStatusSource
    private let panel: PanelControls
    private let desktopOpener: any ClaudeDesktopOpening
    private let tmuxSwitcher: any TmuxSessionSwitching

    init(
        model: AgentPanelModel,
        statusSource: any AgentStatusSource,
        panel: PanelControls,
        desktopOpener: any ClaudeDesktopOpening = ClaudeDesktopOpener(raiseWindowShowing: ClaudeWindowRaiser.raiseWindow(showing:)),
        tmuxSwitcher: any TmuxSessionSwitching = TmuxSessionSwitcher()
    ) {
        self.model = model
        self.statusSource = statusSource
        self.panel = panel
        self.desktopOpener = desktopOpener
        self.tmuxSwitcher = tmuxSwitcher
    }

    enum Outcome: Equatable, Sendable {
        case switched
        case failed(String)
    }

    /// `surfacesFailure` false (Focus mode): a failure is only returned, the panel is not brought back
    /// with the red notice — the caller shows it where the user is looking.
    @discardableResult
    func switchTo(_ agent: AgentSnapshot, surfacesFailure: Bool = true) async -> Outcome {
        let outcome: Outcome
        switch agent.host {
        case .herdr:
            outcome = await focusPane(of: agent)
        case .claudeDesktop(let openURL):
            panel.hide()
            outcome = desktopOpener.openSession(openURL, title: agent.label) ? .switched : .failed("Claude Desktop could not be opened.")
        case .claudeCLI(let tmuxTarget?):
            panel.hide()
            switch await tmuxSwitcher.switchTo(tmuxTarget: tmuxTarget, cwd: agent.cwd) {
            case .switched: outcome = .switched
            case .failed(let message): outcome = .failed(message)
            }
        case .claudeCLI(nil):
            if surfacesFailure { model.reportSwitchFailure(Self.untrackedCliSessionMessage) }
            return .failed(Self.untrackedCliSessionMessage)
        }
        switch outcome {
        case .switched: model.recordSwitch(to: agent.id)
        case .failed(let message): if surfacesFailure { surface(failure: message) }
        }
        return outcome
    }

    static let untrackedCliSessionMessage = AgentTerminalJumper.untrackedCliSessionMessage

    private func focusPane(of agent: AgentSnapshot) async -> Outcome {
        panel.hide()
        guard let paneId = agent.paneId else { return .failed("this agent has no terminal pane.") }
        let result = await statusSource.focus(paneId: paneId)
        return result.succeeded ? .switched : .failed(result.errorMessage ?? "the dashboard could not focus that agent.")
    }

    private func surface(failure message: String) {
        if !panel.isVisible() { panel.show() }   // show() starts from a clean panel, so report after it
        model.reportSwitchFailure(message)
    }
}
