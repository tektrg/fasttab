import Foundation
import ServiceManagement
import OSLog

private let launchAtLoginLogger = Logger(subsystem: "com.trungluong.FastTab", category: "LaunchAtLogin")

@MainActor
final class LaunchAtLoginService: ObservableObject {
    static let shared = LaunchAtLoginService()

    @Published private(set) var isEnabled = false
    @Published private(set) var errorMessage: String?

    private let didInitializeKey = "launchAtLogin.didInitialize"

    private init() {
        refreshStatus()
        enableOnFirstLaunchIfNeeded()
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }

            errorMessage = nil
            refreshStatus()
            launchAtLoginLogger.info("Launch at login updated. enabled=\(self.isEnabled)")
        } catch {
            refreshStatus()
            errorMessage = error.localizedDescription
            launchAtLoginLogger.error("Failed to update launch at login: \(error.localizedDescription)")
        }
    }

    func refreshStatus() {
        isEnabled = SMAppService.mainApp.status == .enabled
    }

    private func enableOnFirstLaunchIfNeeded() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: didInitializeKey) == nil else { return }

        defaults.set(true, forKey: didInitializeKey)
        setEnabled(true)
    }
}
