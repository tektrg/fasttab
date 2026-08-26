import AppKit

/// Relaunches FastTab as a fresh process, then quits this one. Used after
/// changes that only take effect on next launch (source toggles, newly
/// granted Full Disk Access).
func restartFastTab() {
    let bundleURL = Bundle.main.bundleURL
    let config = NSWorkspace.OpenConfiguration()
    config.createsNewApplicationInstance = true
    NSWorkspace.shared.openApplication(at: bundleURL, configuration: config) { _, _ in
        DispatchQueue.main.async {
            NSApp.terminate(nil)
        }
    }
}
