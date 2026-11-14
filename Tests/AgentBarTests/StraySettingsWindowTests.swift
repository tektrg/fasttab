import Testing
@testable import AgentBar

/// SwiftUI's placeholder Settings scene must be recognised (closed + redirected), never the real one.
struct StraySettingsWindowTests {
    @Test func swiftUIPlaceholderSettingsWindowIsStray() {
        #expect(StraySettingsWindow.isStray(identifier: "com_apple_SwiftUI_Settings_window"))
        #expect(StraySettingsWindow.isStray(identifier: "com_apple_SwiftUI_Settings_window-AppWindow-1"))
    }

    @Test func realSettingsAndOtherWindowsAreNotStray() {
        #expect(!StraySettingsWindow.isStray(identifier: nil))
        #expect(!StraySettingsWindow.isStray(identifier: ""))
        #expect(!StraySettingsWindow.isStray(identifier: "AgentBarPanel"))
    }
}
