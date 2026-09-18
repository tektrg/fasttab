import Foundation
import CommandBarKit

enum SlotState: String, Codable, Sendable {
    case live
    case ghost
    case browserFrozen
}

struct OrderedTabSlot: Identifiable, Codable, Equatable, Sendable {
    let slotID: UUID
    var url: String
    var matchKey: String
    var title: String
    var browserName: String
    var profileName: String?
    var state: SlotState
    var boundTabID: Int?
    var windowIndex: Int?
    var tabIndex: Int?
    var ghostedAt: Date?
    var lastSeenLiveAt: Date?
    var isPinned: Bool
    var confirmedInBrowser: Bool

    var id: UUID { slotID }

    enum CodingKeys: String, CodingKey {
        case slotID, url, matchKey, title, browserName, profileName, state
        case boundTabID, windowIndex, tabIndex, ghostedAt, lastSeenLiveAt
        case isPinned, confirmedInBrowser
    }

    init(
        slotID: UUID = UUID(),
        url: String,
        matchKey: String? = nil,
        title: String,
        browserName: String,
        profileName: String? = nil,
        state: SlotState = .live,
        boundTabID: Int? = nil,
        windowIndex: Int? = nil,
        tabIndex: Int? = nil,
        ghostedAt: Date? = nil,
        lastSeenLiveAt: Date? = nil,
        isPinned: Bool = false,
        confirmedInBrowser: Bool = false
    ) {
        self.slotID = slotID
        self.url = url
        self.matchKey = matchKey ?? Frecency.normalizeURL(url)
        self.title = title
        self.browserName = browserName
        self.profileName = profileName
        self.state = state
        self.boundTabID = boundTabID
        self.windowIndex = windowIndex
        self.tabIndex = tabIndex
        self.ghostedAt = ghostedAt
        self.lastSeenLiveAt = lastSeenLiveAt
        self.isPinned = isPinned
        self.confirmedInBrowser = confirmedInBrowser
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.slotID = try container.decode(UUID.self, forKey: .slotID)
        self.url = try container.decode(String.self, forKey: .url)
        self.matchKey = try container.decodeIfPresent(String.self, forKey: .matchKey) ?? Frecency.normalizeURL(url)
        self.title = try container.decode(String.self, forKey: .title)
        self.browserName = try container.decode(String.self, forKey: .browserName)
        self.profileName = try container.decodeIfPresent(String.self, forKey: .profileName)
        self.state = try container.decode(SlotState.self, forKey: .state)
        self.boundTabID = try container.decodeIfPresent(Int.self, forKey: .boundTabID)
        self.windowIndex = try container.decodeIfPresent(Int.self, forKey: .windowIndex)
        self.tabIndex = try container.decodeIfPresent(Int.self, forKey: .tabIndex)
        self.ghostedAt = try container.decodeIfPresent(Date.self, forKey: .ghostedAt)
        self.lastSeenLiveAt = try container.decodeIfPresent(Date.self, forKey: .lastSeenLiveAt)
        self.isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        self.confirmedInBrowser = try container.decodeIfPresent(Bool.self, forKey: .confirmedInBrowser) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(slotID, forKey: .slotID)
        try container.encode(url, forKey: .url)
        try container.encode(matchKey, forKey: .matchKey)
        try container.encode(title, forKey: .title)
        try container.encode(browserName, forKey: .browserName)
        try container.encodeIfPresent(profileName, forKey: .profileName)
        try container.encode(state, forKey: .state)
        try container.encodeIfPresent(boundTabID, forKey: .boundTabID)
        try container.encodeIfPresent(windowIndex, forKey: .windowIndex)
        try container.encodeIfPresent(tabIndex, forKey: .tabIndex)
        try container.encodeIfPresent(ghostedAt, forKey: .ghostedAt)
        try container.encodeIfPresent(lastSeenLiveAt, forKey: .lastSeenLiveAt)
        try container.encode(isPinned, forKey: .isPinned)
        try container.encode(confirmedInBrowser, forKey: .confirmedInBrowser)
    }

    var asSearchResult: BrowserSearchResult {
        BrowserSearchResult(
            title: title,
            url: url,
            browserName: browserName,
            type: .tab,
            timestamp: lastSeenLiveAt ?? ghostedAt ?? Date(),
            windowIndex: windowIndex,
            tabIndex: tabIndex,
            profileName: profileName,
            tabID: boundTabID,
            isPinned: isPinned,
            isGhost: state == .ghost
        )
    }
}
