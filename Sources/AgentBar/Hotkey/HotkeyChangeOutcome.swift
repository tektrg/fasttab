/// What happened when the user picked a new summon shortcut.
enum HotkeyChangeOutcome: Equatable {
    /// The new shortcut is registered and now the active one.
    case applied(AgentHotkeyConfig)
    /// macOS refused the new shortcut; `active` is the one that stays in use.
    case reverted(active: AgentHotkeyConfig, message: String)

    /// The shortcut in force after the attempt.
    var active: AgentHotkeyConfig {
        switch self {
        case .applied(let config): config
        case .reverted(let active, _): active
        }
    }

    /// Plain-English problem to show next to the recorder; nil on success.
    var message: String? {
        if case .reverted(_, let message) = self { return message }
        return nil
    }

    /// `registrationIssue` is the plain-English reason from registering
    /// `requested`, or nil when it worked.
    static func resolve(
        previous: AgentHotkeyConfig, requested: AgentHotkeyConfig, registrationIssue: String?
    ) -> HotkeyChangeOutcome {
        guard let registrationIssue else { return .applied(requested) }
        return .reverted(
            active: previous,
            message: "\(requested.displayName) can't be used. \(registrationIssue) Still using \(previous.displayName)."
        )
    }
}
