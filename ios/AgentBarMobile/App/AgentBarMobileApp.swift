import SwiftUI

@main
struct AgentBarMobileApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup { SettingsView(model: appDelegate.model) }
    }
}
