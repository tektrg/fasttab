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
        let message = AutomationDeniedBanner.message(for: [.chrome, .finder])
        #expect(message.hasPrefix("Google Chrome, Finder can't be read"))
    }
}
