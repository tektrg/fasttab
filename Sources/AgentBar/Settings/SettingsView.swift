import SwiftUI

/// One entry in the Settings sidebar. Each case's content lives in its own
/// `*SettingsView` file; this file only owns the sidebar and routing.
enum SettingsTab: String, CaseIterable, Identifiable, Hashable {
    case general, shortcuts, statusSource, list, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .shortcuts: "Shortcuts"
        case .statusSource: "Status source"
        case .list: "List"
        case .about: "About"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .shortcuts: "keyboard"
        case .statusSource: "antenna.radiowaves.left.and.right"
        case .list: "list.bullet.rectangle"
        case .about: "info.circle"
        }
    }
}

/// Settings window content: a sidebar of tabs (the same layout as FastTab's).
struct SettingsView: View {
    @ObservedObject var settings: AgentBarSettings
    let actions: AgentBarSettingsActions
    let connectionTester: DashboardConnectionTester

    @State private var selection: SettingsTab? = .general

    var body: some View {
        NavigationSplitView {
            List(SettingsTab.allCases, selection: $selection) { tab in
                Label(tab.title, systemImage: tab.systemImage).tag(tab)
            }
            .listStyle(.sidebar)
            // Wide enough for "Status source" in full.
            .navigationSplitViewColumnWidth(min: 200, ideal: 200, max: 240)
        } detail: {
            detail.navigationTitle(currentTab.title)
        }
        .frame(width: Self.width, height: Self.height)
    }

    static let width: CGFloat = 680
    static let height: CGFloat = 420

    private var currentTab: SettingsTab { selection ?? .general }

    @ViewBuilder
    private var detail: some View {
        switch currentTab {
        case .general: GeneralSettingsView(settings: settings)
        case .shortcuts: ShortcutsSettingsView(settings: settings, actions: actions)
        case .statusSource: StatusSourceSettingsView(settings: settings, connectionTester: connectionTester)
        case .list: ListSettingsView(settings: settings)
        case .about: AboutSettingsView()
        }
    }
}
