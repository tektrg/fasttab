import Foundation

enum BrowserResultType: String, Codable, Hashable, Sendable {
    case tab
    case bookmark
    case history

    var sortPriority: Int {
        switch self {
        case .tab: return 0
        case .bookmark: return 1
        case .history: return 2
        }
    }

    var label: String {
        rawValue.capitalized
    }

    var symbolName: String {
        switch self {
        case .tab: return "rectangle.on.rectangle"
        case .bookmark: return "bookmark"
        case .history: return "clock.arrow.circlepath"
        }
    }

    /// Visual dimming hierarchy for list rows:
    /// tabs = normal, bookmarks = dimmer, history = dimmest.
    var dimmingOpacity: Double {
        switch self {
        case .tab: return 1.0
        case .bookmark: return 0.72
        case .history: return 0.52
        }
    }
}

struct BrowserSearchResult: Identifiable, Codable, Hashable, Sendable {
    let title: String
    let url: String
    let browserName: String
    let type: BrowserResultType
    let timestamp: Date
    let windowIndex: Int?
    let tabIndex: Int?
    let windowName: String?
    let bookmarkID: String?
    let profileName: String?
    let folderPath: String?
    let isCurrentFlowActiveTab: Bool

    init(
        title: String,
        url: String,
        browserName: String,
        type: BrowserResultType,
        timestamp: Date,
        windowIndex: Int? = nil,
        tabIndex: Int? = nil,
        windowName: String? = nil,
        bookmarkID: String? = nil,
        profileName: String? = nil,
        folderPath: String? = nil,
        isCurrentFlowActiveTab: Bool = false
    ) {
        self.title = title
        self.url = url
        self.browserName = browserName
        self.type = type
        self.timestamp = timestamp
        self.windowIndex = windowIndex
        self.tabIndex = tabIndex
        self.windowName = windowName
        self.bookmarkID = bookmarkID
        self.profileName = profileName
        self.folderPath = folderPath
        self.isCurrentFlowActiveTab = isCurrentFlowActiveTab
    }

    var id: String {
        switch type {
        case .tab:
            return [browserName, type.rawValue, String(windowIndex ?? 0), String(tabIndex ?? 0), url].joined(separator: "|")
        case .bookmark:
            return [browserName, type.rawValue, bookmarkID ?? url, profileName ?? ""].joined(separator: "|")
        case .history:
            return [browserName, type.rawValue, url, String(timestamp.timeIntervalSince1970)].joined(separator: "|")
        }
    }

    var secondaryBaseText: String {
        switch type {
        case .bookmark:
            if let folderPath, !folderPath.isEmpty {
                return folderPath
            } else {
                return url
            }
        case .tab, .history:
            return url
        }
    }

    func secondaryMetadata(showWindowName: Bool, showProfileName: Bool) -> [String] {
        var metadata: [String] = []

        if showWindowName,
           type == .tab,
           let windowName,
           !windowName.isEmpty {
            metadata.append(windowName)
        }

        if showProfileName,
           let profileName,
           !profileName.isEmpty {
            metadata.append(profileName)
        }

        return metadata
    }

    func secondaryText(showWindowName: Bool, showProfileName: Bool) -> String {
        let metadata = secondaryMetadata(showWindowName: showWindowName, showProfileName: showProfileName)

        guard !metadata.isEmpty else {
            return secondaryBaseText
        }

        return (metadata + [secondaryBaseText]).joined(separator: " • ")
    }

    func matches(query: String) -> Bool {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return true }
        return title.localizedCaseInsensitiveContains(normalized)
            || url.localizedCaseInsensitiveContains(normalized)
    }
}

func sortBrowserSearchResults(_ results: [BrowserSearchResult]) -> [BrowserSearchResult] {
    results.sorted { lhs, rhs in
        if lhs.type.sortPriority != rhs.type.sortPriority {
            return lhs.type.sortPriority < rhs.type.sortPriority
        }

        if lhs.timestamp != rhs.timestamp {
            return lhs.timestamp > rhs.timestamp
        }

        if lhs.browserName != rhs.browserName {
            return lhs.browserName.localizedCompare(rhs.browserName) == .orderedAscending
        }

        return lhs.title.localizedCompare(rhs.title) == .orderedAscending
    }
}

func quickOpenVisibleTabs(from results: [BrowserSearchResult], limit: Int) -> [BrowserSearchResult] {
    Array(results.lazy.filter { !$0.isCurrentFlowActiveTab }.prefix(max(0, limit)))
}
