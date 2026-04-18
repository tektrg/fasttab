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
}

struct BrowserSearchResult: Identifiable, Codable, Hashable, Sendable {
    let title: String
    let url: String
    let browserName: String
    let type: BrowserResultType
    let timestamp: Date
    let windowIndex: Int?
    let tabIndex: Int?
    let bookmarkID: String?
    let profileName: String?
    let folderPath: String?

    init(
        title: String,
        url: String,
        browserName: String,
        type: BrowserResultType,
        timestamp: Date,
        windowIndex: Int? = nil,
        tabIndex: Int? = nil,
        bookmarkID: String? = nil,
        profileName: String? = nil,
        folderPath: String? = nil
    ) {
        self.title = title
        self.url = url
        self.browserName = browserName
        self.type = type
        self.timestamp = timestamp
        self.windowIndex = windowIndex
        self.tabIndex = tabIndex
        self.bookmarkID = bookmarkID
        self.profileName = profileName
        self.folderPath = folderPath
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

    var secondaryText: String {
        switch type {
        case .bookmark:
            if let folderPath, !folderPath.isEmpty {
                return folderPath
            }
            return url
        case .tab, .history:
            return url
        }
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
