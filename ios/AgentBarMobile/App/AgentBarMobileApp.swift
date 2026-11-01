import SwiftUI

@main
struct AgentBarMobileApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup { RootView(settings: appDelegate.model, shell: appDelegate.shell) }
    }
}
