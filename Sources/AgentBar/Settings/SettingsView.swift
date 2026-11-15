import IndieSettings
import SwiftUI

/// One entry in the Settings sidebar. Each case's content lives in its own
/// `*SettingsView` file; this file only owns the sidebar and routing.
enum SettingsTab: String, CaseIterable, Identifiable, Hashable {
    case general, appearance, shortcuts, statusSource, routing, personas, accounts, list, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        case .shortcuts: "Shortcuts"
        case .statusSource: "Status source"
        case .routing: "Routing"
        case .personas: "Personas"
        case .accounts: "Accounts"
        case .list: "List"
        case .about: "About"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "paintbrush"
        case .shortcuts: "keyboard"
        case .statusSource: "antenna.radiowaves.left.and.right"
        case .routing: "arrow.triangle.branch"
        case .personas: "person.2"
        case .accounts: "person.badge.key"
        case .list: "list.bullet.rectangle"
        case .about: "info.circle"
        }
    }
}

extension SettingsTab {
    /// Sidebar group in the shared settings window: About sits in the footer, like Fast Tab's.
    var group: SettingsPaneGroup { self == .about ? .footer : .main }
}

/// Opens Settings on a `SettingsTab`: call sites pass a pane case, never a free-text id.
extension SettingsNavigator {
    func request(_ tab: SettingsTab) { request(tab.id) }
}

/// Settings window content: the shared IndieSettings window with Agent Bar's panes.
/// Each pane's content lives in its own `*SettingsView` file.
struct SettingsView: View {
    @ObservedObject var settings: AgentBarSettings
    let actions: AgentBarSettingsActions
    let connectionTester: DashboardConnectionTester
    var navigator: SettingsNavigator? = nil

    static let width: CGFloat = 680
    static let height: CGFloat = 420
    /// Wide enough for "Status source" in full (the shared default, 170–220, cuts it off).
    static let sidebarWidth = SettingsSidebarWidth(min: 200, ideal: 200, max: 240)

    var body: some View {
        SettingsWindow(
            panes: SettingsTab.allCases.map { tab in
                SettingsPane(id: tab.id, title: tab.title, systemImage: tab.systemImage, group: tab.group) {
                    content(tab)
                }
            },
            navigator: navigator,
            size: CGSize(width: Self.width, height: Self.height),
            sidebarWidth: Self.sidebarWidth)
    }

    @ViewBuilder
    private func content(_ tab: SettingsTab) -> some View {
        switch tab {
        case .general: GeneralSettingsView(settings: settings)
        case .appearance: AppearanceSettingsView(settings: settings)
        case .shortcuts: ShortcutsSettingsView(settings: settings, actions: actions)
        case .statusSource: StatusSourceSettingsView(settings: settings, connectionTester: connectionTester)
        case .routing: RoutingSettingsView(settings: settings)
        case .personas: PersonasSettingsView(settings: settings)
        case .accounts: AccountsSettingsView(settings: settings)
        case .list: ListSettingsView(settings: settings)
        case .about: AboutSettingsView()
        }
    }
}
