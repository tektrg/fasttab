import Foundation
import AppKit

public enum AccessibilityService {
    public static func isTrusted() -> Bool {
        return AXIsProcessTrusted()
    }

    public static func requestPermissions() {
        // Use the string constant directly to avoid Swift 6 concurrency warnings with the CFString pointer
        let promptKey = "AXTrustedCheckOptionPrompt" as NSString
        let options = [promptKey: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)

        // Also open the settings pane directly for convenience
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
