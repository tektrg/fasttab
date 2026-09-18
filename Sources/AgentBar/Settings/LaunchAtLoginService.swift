import Foundation
import ServiceManagement
import OSLog

/// "Launch at login" through the system's login-item service. The system is the
/// source of truth (the user can also flip it in System Settings), so the
/// state is re-read after every change and whenever Settings appears.
/// Adapted from FastTab's service, minus its enable-on-first-launch step:
/// AgentBar starts out not launching at login.
@MainActor
final class LaunchAtLoginService: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var errorMessage: String?

    private let logger = Logger(subsystem: AgentBarIdentity.bundleIdentifier, category: "LaunchAtLogin")

    init() {
        refreshStatus()
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't change this: \(error.localizedDescription)"
            logger.error("Failed to update launch at login: \(error.localizedDescription, privacy: .public)")
        }
        refreshStatus()
    }

    func refreshStatus() {
        isEnabled = SMAppService.mainApp.status == .enabled
    }
}
