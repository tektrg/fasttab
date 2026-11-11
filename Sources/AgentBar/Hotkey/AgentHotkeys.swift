import AppKit
import CommandBarKit
import OSLog

/// Which way a hotkey press moves the selection.
enum CycleDirection: Equatable {
    case forward
    case backward

    var step: Int { self == .forward ? 1 : -1 }
}

/// AgentBar's global shortcuts: the configured key (forward) and the same key
/// with ⇧ added (backward). Carbon hotkeys need no Accessibility permission.
@MainActor
final class AgentHotkeys {
    static let forwardHotkeyID: UInt32 = 1
    static let backwardHotkeyID: UInt32 = 2
    /// Focus mode's own system-wide shortcut (`FocusMode/`).
    static let focusHotkeyID: UInt32 = 3
    static let logSubsystem = AgentBarIdentity.bundleIdentifier

    /// Called for every press of either shortcut.
    var onPressed: (@MainActor @Sendable (CycleDirection) -> Void)?
    /// Called for every press of the Focus mode shortcut.
    var onFocusPressed: (@MainActor @Sendable () -> Void)?

    private let service = GlobalHotkeyService(
        signature: GlobalHotkeyService.fourCharCode("ABAR"),
        logSubsystem: AgentHotkeys.logSubsystem,
        logCategory: "GlobalHotkey"
    )
    private let logger = Logger(subsystem: AgentHotkeys.logSubsystem, category: "GlobalHotkey")

    /// Turns both shortcuts off until the next `register`.
    func suspend() {
        service.unregisterAll()
    }

    private func installPressHandler() {
        service.onHotKeyPressed = { [weak self] id in
            if id == Self.focusHotkeyID {
                self?.onFocusPressed?()
                return
            }
            let direction: CycleDirection = id == Self.backwardHotkeyID ? .backward : .forward
            self?.onPressed?(direction)
        }
    }

    /// Registers (or replaces) the Focus mode shortcut. Returns a plain-English problem, nil on success.
    func registerFocus(_ config: AgentHotkeyConfig) -> String? {
        installPressHandler()
        let result = service.registerShortcut(id: Self.focusHotkeyID, keyCode: config.keyCode, modifiers: config.modifiers)
        let issue = result.userMessage(appName: "AgentBar")
        if let issue {
            logger.error("Focus hotkey \(config.displayName, privacy: .public) unavailable: \(issue, privacy: .public)")
        }
        return issue
    }

    /// Registers the shortcuts, replacing any registered before (so it doubles
    /// as "change shortcut"). Returns a plain-English problem when the main one
    /// could not be taken (the panel then stays reachable by re-launching the
    /// app); nil on success. A missing backward shortcut is only logged.
    func register(_ config: AgentHotkeyConfig) -> String? {
        installPressHandler()

        let forward = service.registerShortcut(id: Self.forwardHotkeyID, keyCode: config.keyCode, modifiers: config.modifiers)
        let issue = forward.userMessage(appName: "AgentBar")
        if let issue {
            logger.error("Summon hotkey \(config.displayName, privacy: .public) unavailable: \(issue, privacy: .public)")
        }

        if let backwardModifiers = config.backwardModifiers {
            let backward = service.registerShortcut(id: Self.backwardHotkeyID, keyCode: config.keyCode, modifiers: backwardModifiers)
            if let message = backward.userMessage(appName: "AgentBar") {
                logger.error("Backward-cycle hotkey unavailable: \(message, privacy: .public)")
            }
        } else {
            // A previous shortcut's backward twin must not stay live.
            service.unregisterShortcut(id: Self.backwardHotkeyID)
            logger.info("Backward-cycle hotkey skipped: the main shortcut already includes ⇧")
        }
        return issue
    }
}
