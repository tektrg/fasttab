import IndieSettings
import SwiftUI
import Testing
@testable import AgentBar

@MainActor
struct SettingsPaneTests {
    @Test func sidebarKeepsAgentBarPaneOrder() {
        let registry = SettingsPaneRegistry(SettingsTab.allCases.map { tab in
            SettingsPane(id: tab.id, title: tab.title, systemImage: tab.systemImage, group: tab.group) { EmptyView() }
        })
        #expect(registry.ids == SettingsTab.allCases.map(\.id))
        #expect(registry.resolvedSelection(nil) == SettingsTab.general.id)
    }

    @Test func sidebarIsWideEnoughForStatusSource() {
        #expect(SettingsView.sidebarWidth.min >= 200)
    }

    @Test func navigatorRequestUsesPaneID() {
        let navigator = SettingsNavigator()
        navigator.request(SettingsTab.statusSource)
        #expect(navigator.requestedPaneID == "statusSource")
    }
}
