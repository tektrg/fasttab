import AppKit

/// One-shot flag: the relaunched process opens the command bar on startup
/// (used when onboarding's "Open FastTab" also needs a restart).
private let openCommandBarAfterRelaunchKey = "FastTab.openCommandBarAfterRelaunch"

/// Relaunches FastTab as a fresh process, then quits this one. Used after
/// changes that only take effect on next launch (source toggles, newly
/// granted Full Disk Access).
func restartFastTab(openCommandBarAfterRelaunch: Bool = false) {
    if openCommandBarAfterRelaunch {
        UserDefaults.standard.set(true, forKey: openCommandBarAfterRelaunchKey)
    }
    let bundleURL = Bundle.main.bundleURL
    let config = NSWorkspace.OpenConfiguration()
    config.createsNewApplicationInstance = true
    NSWorkspace.shared.openApplication(at: bundleURL, configuration: config) { _, error in
        DispatchQueue.main.async {
            // Relaunch failed: keep running, and drop the flag so a later
            // unrelated launch doesn't pop the bar open.
            guard error == nil else {
                UserDefaults.standard.removeObject(forKey: openCommandBarAfterRelaunchKey)
                return
            }
            NSApp.terminate(nil)
        }
    }
}

/// Returns true (once) when the previous process asked this launch to open
/// the command bar, clearing the request.
func consumeOpenCommandBarAfterRelaunchRequest(defaults: UserDefaults = .standard) -> Bool {
    guard defaults.bool(forKey: openCommandBarAfterRelaunchKey) else { return false }
    defaults.removeObject(forKey: openCommandBarAfterRelaunchKey)
    return true
}
