import Foundation

/// Switching to an agent: close the panel at once, ask the status source to
/// focus the agent's terminal tab, then settle the outcome.
///
/// - Success: the switch is recorded for ranking (frecency).
/// - Failure: the switch is NOT recorded (a dead pane must not float to the
///   top), and the panel comes back with a red "Couldn't switch: ..." notice that
///   stays until the user closes it, since by then their eyes are already elsewhere.
///   If the panel was reopened in the meantime it is left as is and only gets the notice.
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

    init(model: AgentPanelModel, statusSource: any AgentStatusSource, panel: PanelControls) {
        self.model = model
        self.statusSource = statusSource
        self.panel = panel
    }

    func switchTo(_ agent: AgentSnapshot) async {
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
