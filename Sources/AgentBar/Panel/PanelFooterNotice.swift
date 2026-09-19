import Foundation

/// The one-line strip at the bottom of the panel for things the user should
/// know but that are not agent rows. A failed switch or row action (both
/// transient) outranks a shortcut problem.
enum PanelFooterNotice: Equatable {
    /// Red, transient: the last switch attempt failed.
    case switchFailed(String)
    /// Red, transient: a Done / Close pane press failed. Carries the whole sentence.
    case actionFailed(String)
    /// Orange, lasting: the global shortcut could not be registered.
    case hotkeyUnavailable(String)

    static func resolve(transient: PanelFooterNotice?, hotkeyIssue: String?) -> PanelFooterNotice? {
        if let transient { return transient }
        if let hotkeyIssue { return .hotkeyUnavailable(hotkeyIssue) }
        return nil
    }

    /// What the user reads.
    var text: String {
        switch self {
        case .switchFailed(let message): "Couldn't switch: \(message)"
        case .actionFailed(let sentence): sentence
        case .hotkeyUnavailable(let message): "\(message) Re-open AgentBar to show this panel."
        }
    }
}
