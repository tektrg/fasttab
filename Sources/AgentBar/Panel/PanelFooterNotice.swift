import Foundation

/// What the panel tells the user at the bottom, apart from agent rows. A failed
/// switch or row action outranks a shortcut problem. Failures stay until the
/// user closes them (✕ / esc) or a newer one replaces them.
enum PanelFooterNotice: Equatable {
    /// Red, closable: the last switch attempt failed.
    case switchFailed(String)
    /// Red, closable: a Done / Close pane / answer / decision failed. Carries the whole sentence.
    case actionFailed(String)
    /// Orange, closable: something went through but the user should check the terminal (a plan answer that left auto mode on).
    case warning(String)
    /// Orange, lasting: the global shortcut could not be registered.
    case hotkeyUnavailable(String)
    /// Green, closable: something the user asked for succeeded and there is no row to show it on
    /// yet (e.g. a brand-new AptusFit worker — it takes a status update or two before its row
    /// appears). Distinct from `.warning`: nothing needs checking, this is good news.
    case created(String)

    static func resolve(failure: PanelFooterNotice?, hotkeyIssue: String?) -> PanelFooterNotice? {
        if let failure { return failure }
        if let hotkeyIssue { return .hotkeyUnavailable(hotkeyIssue) }
        return nil
    }

    /// Failures are shown as a closable card above the footer; the shortcut
    /// problem is a fixed strip in the footer that goes when the shortcut works.
    var isDismissible: Bool {
        switch self {
        case .switchFailed, .actionFailed, .warning, .created: true
        case .hotkeyUnavailable: false
        }
    }

    /// What the user reads.
    var text: String {
        switch self {
        case .switchFailed(let message): "Couldn't switch: \(message)"
        case .actionFailed(let sentence), .warning(let sentence), .created(let sentence): sentence
        case .hotkeyUnavailable(let message): "\(message) Re-open AgentBar to show this panel."
        }
    }
}
