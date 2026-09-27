import Foundation

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
        desktopOpener: any ClaudeDesktopOpening = ClaudeDesktopOpener(),
        tmuxSwitcher: any TmuxSessionSwitching = TmuxSessionSwitcher()
    ) {
        self.model = model
        self.statusSource = statusSource
        self.panel = panel
        self.desktopOpener = desktopOpener
        self.tmuxSwitcher = tmuxSwitcher
    }

    func switchTo(_ agent: AgentSnapshot) async {
        switch agent.host {
        case .herdr:
            await focusPane(of: agent)
        case .claudeDesktop(let openURL):
            panel.hide()
            if desktopOpener.openSession(openURL) {
                model.recordSwitch(to: agent.id)
            } else {
                surface(failure: "Claude Desktop could not be opened.")
            }
        case .claudeCLI(let tmuxTarget?):
            panel.hide()
            switch await tmuxSwitcher.switchTo(tmuxTarget: tmuxTarget, cwd: agent.cwd) {
            case .switched: model.recordSwitch(to: agent.id)
            case .failed(let message): surface(failure: message)
            }
        case .claudeCLI(nil):
            model.reportSwitchFailure(Self.untrackedCliSessionMessage)
        }
    }

    static let untrackedCliSessionMessage =
        "this Claude CLI session runs in a terminal outside herdr and tmux — switch to it there."

    private func focusPane(of agent: AgentSnapshot) async {
        panel.hide()
        guard let paneId = agent.paneId else {
            surface(failure: "this agent has no terminal pane.")
            return
        }
        let result = await statusSource.focus(paneId: paneId)
        if result.succeeded {
            model.recordSwitch(to: agent.id)
        } else {
            surface(failure: result.errorMessage ?? "the dashboard could not focus that agent.")
        }
    }

    private func surface(failure message: String) {
        if !panel.isVisible() { panel.show() }   // show() starts from a clean panel, so report after it
        model.reportSwitchFailure(message)
    }
}
