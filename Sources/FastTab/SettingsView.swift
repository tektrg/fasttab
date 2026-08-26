import SwiftUI

/// One entry in the Settings sidebar. Each case's content lives in its own
/// `*SettingsView` file — this file only owns the sidebar and routing.
enum SettingsTab: String, CaseIterable, Identifiable, Hashable {
    case general, appearance, shortcuts, sources, sync, advanced, license, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .appearance: return "Appearance"
        case .shortcuts: return "Shortcuts"
        case .sources: return "Sources"
        case .sync: return "Sync"
        case .advanced: return "Advanced"
        case .license: return "License"
        case .about: return "About"
        }
    }

    var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .appearance: return "paintbrush"
        case .shortcuts: return "keyboard"
        case .sources: return "list.bullet.rectangle"
        case .sync: return "icloud"
        case .advanced: return "wrench.and.screwdriver"
        case .license: return "key"
        case .about: return "info.circle"
        }
    }

    /// Top, ungrouped rows in the sidebar.
    static let primaryTabs: [SettingsTab] = [.general, .appearance, .shortcuts, .sources, .sync]

    /// Rows under the sidebar's "Advanced" header.
    static let advancedTabs: [SettingsTab] = [.advanced, .license]
}

/// Settings window: a sidebar of tabs (mirrors the macOS System Settings
/// layout) with each tab's content in its own file. Split out once the
/// previous single scrolling `Form` grew past a dozen sections.
struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var licenseService: LicenseService

    @State private var selection: SettingsTab? = .general

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
                .navigationTitle(currentTab.title)
        }
        .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 220)
        .frame(width: 680, height: 420)
    }

    private var sidebar: some View {
        List(selection: $selection) {
            Section {
                ForEach(SettingsTab.primaryTabs) { tab in
                    Label(tab.title, systemImage: tab.systemImage)
                        .tag(tab)
                }
            }

            Section("Advanced") {
                ForEach(SettingsTab.advancedTabs) { tab in
                    Label(tab.title, systemImage: tab.systemImage)
                        .tag(tab)
                }
            }

            Section {
                Label(SettingsTab.about.title, systemImage: SettingsTab.about.systemImage)
                    .tag(SettingsTab.about)
            }
        }
        .listStyle(.sidebar)
    }

    private var currentTab: SettingsTab {
        selection ?? .general
    }

    @ViewBuilder
    private var detail: some View {
        switch currentTab {
        case .general:
            GeneralSettingsView()
        case .appearance:
            AppearanceSettingsView()
        case .shortcuts:
            ShortcutsSettingsView()
        case .sources:
            SourcesSettingsView()
        case .sync:
            Form { SyncSettingsSection() }
                .formStyle(.grouped)
        case .advanced:
            AdvancedSettingsView()
        case .license:
            LicenseSettingsView()
        case .about:
            AboutSettingsView()
        }
    }
}
