import Foundation

/// The one-line strip at the bottom of the panel for things the user should
/// know but that are not agent rows. A failed switch outranks a shortcut problem.
enum PanelFooterNotice: Equatable {
    /// Red, transient: the last switch attempt failed.
    case switchFailed(String)
    /// Orange, lasting: the global shortcut could not be registered.
    case hotkeyUnavailable(String)

    static func resolve(switchError: String?, hotkeyIssue: String?) -> PanelFooterNotice? {
        if let switchError { return .switchFailed(switchError) }
        if let hotkeyIssue { return .hotkeyUnavailable(hotkeyIssue) }
        return nil
    }

    /// What the user reads.
    var text: String {
        switch self {
        case .switchFailed(let message): "Couldn't switch: \(message)"
        case .hotkeyUnavailable(let message): "\(message) Re-open AgentBar to show this panel."
        }
    }
}
