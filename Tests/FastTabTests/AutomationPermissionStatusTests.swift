import Foundation
import CoreServices
import Testing
@testable import FastTab

struct AutomationPermissionStatusTests {
    @Test func mapsAppleEventResultCodes() {
        #expect(AutomationPermissionStatus(appleEventResult: OSStatus(noErr)) == .granted)
        #expect(AutomationPermissionStatus(appleEventResult: -1743) == .denied)
        #expect(AutomationPermissionStatus(appleEventResult: -1744) == .notYetAsked)
        #expect(AutomationPermissionStatus(appleEventResult: -600) == .appNotRunning)
        #expect(AutomationPermissionStatus(appleEventResult: -50) == .unknown)
    }

    @Test func deniedMessageNamesEverySource() {
        #expect(AutomationDeniedBanner.message(for: [.chrome, .finder]).hasPrefix("Google Chrome and Finder can't be read"))
        #expect(AutomationDeniedBanner.message(for: [.chrome, .edge, .finder]).hasPrefix("Google Chrome, Microsoft Edge and Finder can't be read"))
    }

    @Test func extensionConnectedChromiumIsNotDenied() {
        let statuses: [SearchSource: AutomationPermissionStatus] = [.chrome: .denied, .edge: .denied, .finder: .denied]
        let tracked: [SearchSource] = [.chrome, .edge, .finder]

        let served = AutomationPermissionStore.deniedSources(
            tracked: tracked, statuses: statuses,
            extensionEnabled: true, extensionConnectedAppNames: ["Google Chrome"]
        )
        #expect(served == [.edge, .finder])

        let extensionOff = AutomationPermissionStore.deniedSources(
            tracked: tracked, statuses: statuses,
            extensionEnabled: false, extensionConnectedAppNames: ["Google Chrome"]
        )
        #expect(extensionOff == [.chrome, .edge, .finder])
    }
}
