import SwiftUI
import AppKit

/// One entry in the Settings sidebar. Each case's content lives in its own
/// `*SettingsView` file — this file only owns the sidebar and routing.
enum SettingsTab: String, CaseIterable, Identifiable, Hashable {
    case general, appearance, shortcuts, sources, bookmarks, sync, searchAliases, advanced, license, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .appearance: return "Appearance"
        case .shortcuts: return "Shortcuts"
        case .sources: return "Sources"
        case .bookmarks: return "Bookmarks"
        case .sync: return "Sync"
        case .searchAliases: return "Search Aliases"
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
        case .bookmarks: return "bookmark"
        case .sync: return "icloud"
        case .searchAliases: return "magnifyingglass"
        case .advanced: return "wrench.and.screwdriver"
        case .license: return "key"
        case .about: return "info.circle"
        }
    }

    /// Top, ungrouped rows in the sidebar.
    static let primaryTabs: [SettingsTab] = [.general, .appearance, .shortcuts, .sources, .bookmarks, .sync]

    /// Rows under the sidebar's "Advanced" header.
    static let advancedTabs: [SettingsTab] = [.searchAliases, .advanced, .license]
}

/// Lets code outside the Settings window (e.g. the command bar's banners)
/// open Settings on a specific sidebar tab. `SettingsView` consumes the
/// request whether it is already open or appears in response.
@MainActor
final class SettingsNavigator: ObservableObject {
    static let shared = SettingsNavigator()

    @Published var requestedTab: SettingsTab?

    func open(_ tab: SettingsTab, using openSettings: OpenSettingsAction) {
        requestedTab = tab
        NSApp.activate(ignoringOtherApps: true)
        openSettings()
    }
}

/// Settings window: a sidebar of tabs (mirrors the macOS System Settings
/// layout) with each tab's content in its own file. Split out once the
/// previous single scrolling `Form` grew past a dozen sections.
struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var licenseService: LicenseService

    @State private var selection: SettingsTab? = .general
    @ObservedObject private var navigator = SettingsNavigator.shared

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
                .navigationTitle(currentTab.title)
        }
        .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 220)
        .frame(width: 680, height: 420)
        .onChange(of: navigator.requestedTab, initial: true) { _, requested in
            guard let requested else { return }
            selection = requested
            navigator.requestedTab = nil
        }
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
        case .bookmarks:
            BookmarksSettingsView()
        case .sync:
            Form { SyncSettingsSection() }
                .formStyle(.grouped)
        case .searchAliases:
            Form { SearchAliasSettingsSection() }
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
