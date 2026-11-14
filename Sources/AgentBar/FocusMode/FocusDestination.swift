import Foundation

/// Where Focus mode's "Go to …" button takes the user (pure, unit-tested): the agent's real home,
/// named by its host, or why there is none. The jump itself is the list's Return (`model.onActivate`
/// → `AgentSwitchCoordinator`); this only names it and refuses the jumps that cannot work, so the
/// button is never a silent no-op.
struct FocusDestination: Equatable {
    /// "herdr pane", "Claude Desktop", "tmux · work", "Open in Claude", "Air", "No known home".
    let label: String
    let isEnabled: Bool
    /// Why the button is disabled; nil when enabled.
    let reason: String?

    /// The machine id herdr gives the Air's panes (`air-m1:w3:p2`).
    static let otherMacPanePrefix = "air-m1:"
    static let otherMacReason = "Runs on Air — open it there"
    static let noHomeReason = "No known home"

    /// The button's title.
    var buttonTitle: String {
        isEnabled ? (label == "Open in Claude" ? label : "Go to \(label)") : label
    }

    init(label: String, isEnabled: Bool, reason: String?) {
        self.label = label
        self.isEnabled = isEnabled
        self.reason = reason
    }

    init(agent: AgentSnapshot) {
        switch agent.host {
        case .claudeDesktop:
            self.init(label: agent.section == .sleeping ? "Open in Claude" : "Claude Desktop", isEnabled: true, reason: nil)
        case .claudeCLI(let target?):
            let session = target.split(separator: ":", maxSplits: 1).first.map(String.init) ?? target
            self.init(label: "tmux · \(session)", isEnabled: true, reason: nil)
        case .claudeCLI(nil):
            self.init(label: Self.noHomeReason, isEnabled: false, reason: Self.noHomeReason)
        case .herdr:
            guard let paneId = agent.paneId, agent.canFocus else {
                self.init(label: Self.noHomeReason, isEnabled: false, reason: Self.noHomeReason)
                return
            }
            if paneId.hasPrefix(Self.otherMacPanePrefix) {
                self.init(label: "Runs on Air", isEnabled: false, reason: Self.otherMacReason)
            } else {
                self.init(label: "herdr pane", isEnabled: true, reason: nil)
            }
        }
    }
}
