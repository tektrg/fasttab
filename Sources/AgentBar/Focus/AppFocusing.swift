import AppKit

/// The few "which app has the keyboard" operations `TextInputActivation` needs,
/// behind a protocol so the focus rules are unit-tested with a fake.
@MainActor
protocol AppFocusing: AnyObject {
    var ownProcessID: pid_t { get }
    /// The app macOS currently treats as frontmost (the one dictation tools type into).
    var frontmostProcessID: pid_t? { get }
    func activateSelf()
    /// Brings another app to the front; false when that app is gone.
    @discardableResult func activate(processID: pid_t) -> Bool
}

/// The real thing: `NSWorkspace` for the lookup, `NSApp` / `NSRunningApplication` for activation.
@MainActor
final class SystemAppFocus: AppFocusing {
    var ownProcessID: pid_t { ProcessInfo.processInfo.processIdentifier }

    var frontmostProcessID: pid_t? { NSWorkspace.shared.frontmostApplication?.processIdentifier }

    func activateSelf() {
        // Same call the Settings window uses: an accessory app is never frontmost by itself.
        NSApp.activate(ignoringOtherApps: true)
    }

    func activate(processID: pid_t) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: processID), !app.isTerminated else { return false }
        // macOS 14 cooperative activation: the active app hands the front to the next one.
        NSApp.yieldActivation(to: app)
        return app.activate(options: [])
    }
}
