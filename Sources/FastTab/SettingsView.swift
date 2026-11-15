import SwiftUI
import IndieSettings
import AppKit

/// One entry in the Settings sidebar. Each case's content lives in its own
/// `*SettingsView` file — this file only owns the sidebar and routing.
enum SettingsTab: String, CaseIterable, Identifiable, Hashable {
    case general, appearance, shortcuts, views, sources, bookmarks, highlights, sync, searchAliases, advanced, experimental, license, feedback, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .appearance: return "Appearance"
        case .shortcuts: return "Shortcuts"
        case .views: return "Views"
        case .sources: return "Sources"
        case .bookmarks: return "Bookmarks"
        case .highlights: return "Highlights"
        case .sync: return "Sync"
        case .searchAliases: return "Search Aliases"
        case .advanced: return "Advanced"
        case .experimental: return "Experimental"
        case .license: return "License"
        case .feedback: return FastTabFeedback.menuTitle
        case .about: return "About"
        }
    }

    var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .appearance: return "paintbrush"
        case .shortcuts: return "keyboard"
        case .views: return "square.stack.3d.up"
        case .sources: return "list.bullet.rectangle"
        case .bookmarks: return "bookmark"
        case .highlights: return "highlighter"
        case .sync: return "icloud"
        case .searchAliases: return "magnifyingglass"
        case .advanced: return "wrench.and.screwdriver"
        case .experimental: return "flask"
        case .license: return "key"
        case .feedback: return FastTabFeedback.symbolName
        case .about: return "info.circle"
        }
    }
}

extension SettingsTab {
    /// Sidebar group in the shared settings window.
    var group: SettingsPaneGroup {
        switch self {
        case .searchAliases, .advanced, .experimental, .license: return .advanced
        case .feedback, .about: return .footer
        default: return .main
        }
    }

    @MainActor
    var pane: SettingsPane {
        switch self {
        // Shared Feedback pane (FeedbackCenterView + news dot), titled with Fast Tab's menu title.
        case .feedback:
            return .feedback(center: FastTabFeedback.center, title: title, systemImage: systemImage, id: id)
        default:
            return SettingsPane(id: id, title: title, systemImage: systemImage, group: group) { content }
        }
    }

    @MainActor @ViewBuilder
    private var content: some View {
        switch self {
        case .general: GeneralSettingsView()
        case .appearance: AppearanceSettingsView()
        case .shortcuts: ShortcutsSettingsView()
        case .views: CustomViewsSettingsView()
        case .sources: SourcesSettingsView()
        case .bookmarks: BookmarksSettingsView()
        case .highlights: HighlightsSettingsView()
        case .sync: Form { SyncSettingsSection() }.formStyle(.grouped)
        case .searchAliases: Form { SearchAliasSettingsSection() }.formStyle(.grouped)
        case .advanced: AdvancedSettingsView()
        case .experimental: ExperimentalSettingsView()
        case .license: LicenseSettingsView()
        case .feedback: EmptyView() // built by `pane` as the shared Feedback pane
        // Fast Tab keeps its own About: the shared one has no copy-email button or setup replay.
        case .about: AboutSettingsView()
        }
    }
}

/// Opens Settings on a `SettingsTab` from outside the window (e.g. the command bar's banners).
/// Wraps the shared navigator so call sites pass a pane case, never a free-text id.
extension SettingsNavigator {
    static let shared = SettingsNavigator()

    func request(_ tab: SettingsTab) { request(tab.id) }

    func open(_ tab: SettingsTab, using openSettings: OpenSettingsAction) {
        open(tab.id, using: openSettings)
    }
}

/// Settings window: the shared IndieSettings window with Fast Tab's panes.
/// Each pane's content lives in its own `*SettingsView` file.
struct SettingsView: View {
    var body: some View {
        SettingsWindow(
            panes: SettingsTab.allCases.map(\.pane),
            navigator: SettingsNavigator.shared)
    }
}
