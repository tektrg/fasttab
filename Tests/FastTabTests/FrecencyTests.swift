import Foundation
import Testing
@testable import FastTab

// MARK: - URL normalization

@Test func normalizeURLLowercasesSchemeAndHost() async throws {
    #expect(Frecency.normalizeURL("HTTPS://Example.COM/path") == "https://example.com/path")
}

@Test func normalizeURLStripsQueryAndFragment() async throws {
    #expect(
        Frecency.normalizeURL("https://example.com/path?q=1&x=2#frag") == "https://example.com/path"
    )
}

@Test func normalizeURLStripsTrailingSlashExceptRoot() async throws {
    #expect(Frecency.normalizeURL("https://example.com/path/") == "https://example.com/path")
    #expect(Frecency.normalizeURL("https://example.com/") == "https://example.com/")
}

@Test func normalizeURLPreservesPath() async throws {
    #expect(
        Frecency.normalizeURL("https://news.ycombinator.com/item?id=123") ==
            "https://news.ycombinator.com/item"
    )
}

@Test func normalizeURLReturnsOriginalOnParseFailure() async throws {
    #expect(Frecency.normalizeURL("not a url") == "not a url")
}

// MARK: - Key construction

@Test func keyCollapsesNilProfileToStar() async throws {
    let key = Frecency.key(browser: "Google Chrome", profile: nil, url: "https://example.com/a")
    #expect(key == "Google Chrome|*|https://example.com/a")
}

@Test func keyCollapsesEmptyProfileToStar() async throws {
    let key = Frecency.key(browser: "Google Chrome", profile: "  ", url: "https://example.com/a")
    #expect(key == "Google Chrome|*|https://example.com/a")
}

@Test func keyKeepsExplicitProfile() async throws {
    let key = Frecency.key(browser: "Google Chrome", profile: "Work", url: "https://example.com/a")
    #expect(key == "Google Chrome|Work|https://example.com/a")
}

@Test func keyNormalizesURLBeforeJoining() async throws {
    let key = Frecency.key(browser: "Safari", profile: nil, url: "HTTPS://Example.com/A/?x=1")
    #expect(key == "Safari|*|https://example.com/A")
}

// MARK: - Score / decay math

@Test func scoreIsCountAtZeroDelta() async throws {
    let now = Date()
    let entry = FrecencyEntry(count: 4, lastVisit: now, cachedScore: 4, cachedScoreAt: now)
    #expect(abs(Frecency.score(entry, now: now) - 4.0) < 1e-9)
}

@Test func scoreHalvesAtOneHalfLife() async throws {
    let now = Date()
    let threeDaysAgo = now.addingTimeInterval(-3 * 86_400)
    let entry = FrecencyEntry(count: 4, lastVisit: threeDaysAgo, cachedScore: 4, cachedScoreAt: threeDaysAgo)
    #expect(abs(Frecency.score(entry, now: now) - 2.0) < 1e-6)
}

@Test func scoreFutureTimestampClampsToCount() async throws {
    let now = Date()
    let futureEntry = FrecencyEntry(
        count: 10,
        lastVisit: now.addingTimeInterval(3_600),
        cachedScore: 10,
        cachedScoreAt: now
    )
    #expect(abs(Frecency.score(futureEntry, now: now) - 10.0) < 1e-9)
}

@Test func applyVisitAccumulatesDecayedCount() async throws {
    let now = Date()
    let threeDaysAgo = now.addingTimeInterval(-3 * 86_400)
    var entry = FrecencyEntry(count: 4, lastVisit: threeDaysAgo, cachedScore: 4, cachedScoreAt: threeDaysAgo)
    Frecency.applyVisit(&entry, weight: 1.0, now: now)
    // Decayed count (2.0) + new visit (1.0) = 3.0
    #expect(abs(entry.count - 3.0) < 1e-6)
    #expect(entry.lastVisit == now)
}

@Test func applyVisitOnFreshEntryEqualsCountPlusWeight() async throws {
    let now = Date()
    var entry = Frecency.newEntry(weight: 1.0, now: now)
    Frecency.applyVisit(&entry, weight: 1.0, now: now)
    #expect(abs(entry.count - 2.0) < 1e-9)
}

// MARK: - Eviction

@Test func shouldEvictAfterMaxAge() async throws {
    let now = Date()
    let veryOld = now.addingTimeInterval(-22 * 86_400)
    let entry = FrecencyEntry(count: 5, lastVisit: veryOld, cachedScore: 5, cachedScoreAt: veryOld)
    #expect(Frecency.shouldEvict(entry, now: now))
}

@Test func shouldNotEvictWithinMaxAge() async throws {
    let now = Date()
    let recent = now.addingTimeInterval(-7 * 86_400)
    let entry = FrecencyEntry(count: 5, lastVisit: recent, cachedScore: 5, cachedScoreAt: recent)
    #expect(!Frecency.shouldEvict(entry, now: now))
}

// MARK: - Window-title profile extraction

@Test func profileFromWindowTitleExtractsChromeSuffix() async throws {
    #expect(Frecency.profileFromWindowTitle("Inbox (12) - Trung (Work)") == "Trung (Work)")
}

@Test func profileFromWindowTitleSkipsAppName() async throws {
    #expect(Frecency.profileFromWindowTitle("Some Page - Google Chrome") == nil)
}

@Test func profileFromWindowTitleReturnsNilWhenNoSeparator() async throws {
    #expect(Frecency.profileFromWindowTitle("Plain Title") == nil)
}

// MARK: - Frecency-aware sort integration

@Test func sortPrefersHigherFrecencyAmongTabs() async throws {
    let now = Date()
    let oldButHot = BrowserSearchResult(
        title: "Daily-driver",
        url: "https://gmail.com/inbox",
        browserName: "Google Chrome",
        type: .tab,
        timestamp: now.addingTimeInterval(-3_600)
    )
    let recentButCold = BrowserSearchResult(
        title: "Just-opened",
        url: "https://random.example.com/x",
        browserName: "Google Chrome",
        type: .tab,
        timestamp: now
    )

    let scoreLookup: (BrowserSearchResult) -> Double = { result in
        result.url == "https://gmail.com/inbox" ? 100.0 : 0.5
    }

    let sorted = sortBrowserSearchResults([recentButCold, oldButHot], frecencyScore: scoreLookup)
    #expect(sorted.first?.url == "https://gmail.com/inbox")
}

@Test func sortFallsBackToRecencyWhenNoFrecencyProvided() async throws {
    // Empty-query / quick-open path passes no frecency lookup. Recency must win
    // so the tab the user just switched to is always at the top, regardless
    // of how frequent another tab is.
    let now = Date()
    let oldButHot = BrowserSearchResult(
        title: "Daily-driver",
        url: "https://gmail.com/inbox",
        browserName: "Google Chrome",
        type: .tab,
        timestamp: now.addingTimeInterval(-3_600)
    )
    let justUsed = BrowserSearchResult(
        title: "Just-opened",
        url: "https://random.example.com/x",
        browserName: "Google Chrome",
        type: .tab,
        timestamp: now
    )

    let sorted = sortBrowserSearchResults([oldButHot, justUsed])
    #expect(sorted.first?.url == "https://random.example.com/x")
}

@Test func sortPinsAudibleTabAboveMoreRecentTabsWithNoFrecencyProvided() async throws {
    // The empty-query / quick-open view (what you see the instant the bar
    // opens, before typing) passes no frecency lookup — this exercises the
    // same no-frecency fallback as sortFallsBackToRecencyWhenNoFrecencyProvided,
    // but with an audible tab in the mix: it must still win over a more
    // recently-used tab, exactly like the frecency path does.
    let now = Date()
    let audibleTab = BrowserSearchResult(
        title: "Now playing",
        url: "https://open.spotify.com/track/abc",
        browserName: "Google Chrome",
        type: .tab,
        timestamp: now.addingTimeInterval(-3_600),
        isPinnedAudibleTab: true
    )
    let justUsed = BrowserSearchResult(
        title: "Just-opened",
        url: "https://random.example.com/x",
        browserName: "Google Chrome",
        type: .tab,
        timestamp: now
    )

    let sorted = sortBrowserSearchResults([justUsed, audibleTab])
    #expect(sorted.first?.url == "https://open.spotify.com/track/abc")
}

@Test func sortKeepsTabsAboveBookmarksEvenWithFrecency() async throws {
    let now = Date()
    let coldTab = BrowserSearchResult(
        title: "Cold tab",
        url: "https://example.com/a",
        browserName: "Google Chrome",
        type: .tab,
        timestamp: now
    )
    let hotBookmark = BrowserSearchResult(
        title: "Hot bookmark",
        url: "https://example.com/b",
        browserName: "Google Chrome",
        type: .bookmark,
        timestamp: now
    )

    let scoreLookup: (BrowserSearchResult) -> Double = { _ in 0 }
    let sorted = sortBrowserSearchResults([hotBookmark, coldTab], frecencyScore: scoreLookup)
    #expect(sorted.first?.type == .tab)
}

@Test func sortPinsAudibleTabAboveHigherFrecencyTabs() async throws {
    let now = Date()
    let audibleTab = BrowserSearchResult(
        title: "Now playing",
        url: "https://open.spotify.com/track/abc",
        browserName: "Google Chrome",
        type: .tab,
        timestamp: now.addingTimeInterval(-3_600),
        isPinnedAudibleTab: true
    )
    let dailyDriver = BrowserSearchResult(
        title: "Daily-driver",
        url: "https://gmail.com/inbox",
        browserName: "Google Chrome",
        type: .tab,
        timestamp: now
    )

    let scoreLookup: (BrowserSearchResult) -> Double = { result in
        result.url == "https://gmail.com/inbox" ? 100.0 : 0.5
    }

    let sorted = sortBrowserSearchResults([dailyDriver, audibleTab], frecencyScore: scoreLookup)
    #expect(sorted.first?.url == "https://open.spotify.com/track/abc")
}

// MARK: - Mute toggle

@Test func settingMutedDropsPinnedAudibleFlagWhenMuted() async throws {
    let playing = BrowserSearchResult(
        title: "Now playing",
        url: "https://open.spotify.com/track/abc",
        browserName: "Google Chrome",
        type: .tab,
        timestamp: Date(),
        isAudible: true,
        isMuted: false,
        isPinnedAudibleTab: true
    )

    let muted = playing.settingMuted(true)
    #expect(muted.isMuted == true)
    #expect(muted.isPinnedAudibleTab == false)
    #expect(muted.isAudible == true) // Chrome keeps playing — only silenced, not stopped

    let unmuted = muted.settingMuted(false)
    #expect(unmuted.isMuted == false)
    #expect(unmuted.isPinnedAudibleTab == true)
}

// MARK: - Cross-type duplicate-page collapsing

@Test func deduplicatingSamePagesPrefersLiveTabOverHistoryAndBookmark() async throws {
    let now = Date()
    let tab = BrowserSearchResult(
        title: "Delivery Run - SpeechToDo | Notion",
        url: "https://notion.so/delivery-run",
        browserName: "Google Chrome",
        type: .tab,
        timestamp: now.addingTimeInterval(-3_600)
    )
    let history = BrowserSearchResult(
        title: "(2) Delivery Run - SpeechToDo | Notion",
        url: "https://notion.so/delivery-run",
        browserName: "Google Chrome",
        type: .history,
        timestamp: now
    )
    let bookmark = BrowserSearchResult(
        title: "Delivery Run - SpeechToDo | Notion",
        url: "https://notion.so/delivery-run",
        browserName: "Google Chrome",
        type: .bookmark,
        timestamp: now.addingTimeInterval(-7_200)
    )

    let deduped = deduplicatingSamePages([history, bookmark, tab]) { _ in 0 }
    #expect(deduped.count == 1)
    #expect(deduped.first?.type == .tab)
}

@Test func deduplicatingSamePagesPrefersHigherFrecencyAmongHistoryDuplicates() async throws {
    let now = Date()
    let coldButRecent = BrowserSearchResult(
        title: "Delivery Run", url: "https://notion.so/delivery-run",
        browserName: "Google Chrome", type: .history, timestamp: now
    )
    let hotButOlder = BrowserSearchResult(
        title: "Delivery Run", url: "https://notion.so/delivery-run",
        browserName: "Google Chrome", type: .history, timestamp: now.addingTimeInterval(-86_400)
    )

    let scoreLookup: (BrowserSearchResult) -> Double = { result in
        result.timestamp == hotButOlder.timestamp ? 100.0 : 0.5
    }
    let deduped = deduplicatingSamePages([coldButRecent, hotButOlder], frecencyScore: scoreLookup)
    #expect(deduped.count == 1)
    #expect(deduped.first?.timestamp == hotButOlder.timestamp)
}

@Test func deduplicatingSamePagesFallsBackToRecencyWhenFrecencyTied() async throws {
    let now = Date()
    let older = BrowserSearchResult(
        title: "Delivery Run", url: "https://notion.so/delivery-run",
        browserName: "Google Chrome", type: .history, timestamp: now.addingTimeInterval(-86_400)
    )
    let newer = BrowserSearchResult(
        title: "Delivery Run", url: "https://notion.so/delivery-run",
        browserName: "Google Chrome", type: .history, timestamp: now
    )

    let deduped = deduplicatingSamePages([older, newer]) { _ in 0 }
    #expect(deduped.count == 1)
    #expect(deduped.first?.timestamp == newer.timestamp)
}

@Test func deduplicatingSamePagesKeepsDifferentProfilesApart() async throws {
    let now = Date()
    let personal = BrowserSearchResult(
        title: "Delivery Run", url: "https://notion.so/delivery-run",
        browserName: "Google Chrome", type: .history, timestamp: now, profileName: "Personal"
    )
    let work = BrowserSearchResult(
        title: "Delivery Run", url: "https://notion.so/delivery-run",
        browserName: "Google Chrome", type: .history, timestamp: now, profileName: "Work"
    )

    let deduped = deduplicatingSamePages([personal, work]) { _ in 0 }
    #expect(deduped.count == 2)
}

@Test func deduplicatingSamePagesKeepsDifferentPagesApartWhenTitlesDiffer() async throws {
    let first = BrowserSearchResult(
        title: "cats - Google Search", url: "https://google.com/search?q=cats",
        browserName: "Google Chrome", type: .history, timestamp: Date()
    )
    let second = BrowserSearchResult(
        title: "dogs - Google Search", url: "https://google.com/search?q=dogs",
        browserName: "Google Chrome", type: .history, timestamp: Date()
    )

    let deduped = deduplicatingSamePages([first, second]) { _ in 0 }
    #expect(deduped.count == 2)
}

// MARK: - Pinned tab top priority

@Test func sortPrefersPinnedTabOverSentLinksAndUnpinnedTabs() async throws {
    let now = Date()
    let pinnedTab = BrowserSearchResult(
        title: "Pinned Tab",
        url: "https://pinned.example.com",
        browserName: "Google Chrome",
        type: .tab,
        timestamp: now.addingTimeInterval(-7_200),
        isPinned: true
    )
    let sentLink = BrowserSearchResult(
        title: "Sent Link",
        url: "https://sent.example.com",
        browserName: "FastTab",
        type: .sent,
        timestamp: now
    )
    let unpinnedTab = BrowserSearchResult(
        title: "Recent Unpinned Tab",
        url: "https://unpinned.example.com",
        browserName: "Google Chrome",
        type: .tab,
        timestamp: now
    )
    let bookmark = BrowserSearchResult(
        title: "Bookmark",
        url: "https://bookmark.example.com",
        browserName: "Google Chrome",
        type: .bookmark,
        timestamp: now
    )
    let history = BrowserSearchResult(
        title: "History",
        url: "https://history.example.com",
        browserName: "Google Chrome",
        type: .history,
        timestamp: now
    )

    let sorted = sortBrowserSearchResults([history, bookmark, unpinnedTab, sentLink, pinnedTab])
    #expect(sorted.count == 5)
    #expect(sorted[0].url == "https://pinned.example.com")
    #expect(sorted[1].url == "https://sent.example.com")
    #expect(sorted[2].url == "https://unpinned.example.com")
}

@Test func sortPrefersPinnedTabOverHigherFrecencyOrAudibleUnpinnedTab() async throws {
    let now = Date()
    let pinnedColdTab = BrowserSearchResult(
        title: "Pinned Cold Tab",
        url: "https://pinned.example.com",
        browserName: "Google Chrome",
        type: .tab,
        timestamp: now.addingTimeInterval(-10_000),
        isPinned: true
    )
    let audibleUnpinnedTab = BrowserSearchResult(
        title: "Audible Playing Tab",
        url: "https://music.example.com",
        browserName: "Google Chrome",
        type: .tab,
        timestamp: now,
        isPinnedAudibleTab: true
    )
    let hotUnpinnedTab = BrowserSearchResult(
        title: "Hot Tab",
        url: "https://hot.example.com",
        browserName: "Google Chrome",
        type: .tab,
        timestamp: now
    )

    let scoreLookup: (BrowserSearchResult) -> Double = { result in
        result.url == "https://hot.example.com" ? 999.0 : 0.0
    }

    let sorted = sortBrowserSearchResults([hotUnpinnedTab, audibleUnpinnedTab, pinnedColdTab], frecencyScore: scoreLookup)
    #expect(sorted[0].url == "https://pinned.example.com")
    #expect(sorted[1].url == "https://music.example.com")
    #expect(sorted[2].url == "https://hot.example.com")
}

@Test func sortPreservesOrderAmongMultiplePinnedTabsByTimestampOrFrecency() async throws {
    let now = Date()
    let pinnedOld = BrowserSearchResult(
        title: "Pinned Old",
        url: "https://old.example.com",
        browserName: "Google Chrome",
        type: .tab,
        timestamp: now.addingTimeInterval(-3_600),
        isPinned: true
    )
    let pinnedNew = BrowserSearchResult(
        title: "Pinned New",
        url: "https://new.example.com",
        browserName: "Google Chrome",
        type: .tab,
        timestamp: now,
        isPinned: true
    )
    let unpinned = BrowserSearchResult(
        title: "Unpinned",
        url: "https://unpinned.example.com",
        browserName: "Google Chrome",
        type: .tab,
        timestamp: now.addingTimeInterval(10)
    )

    let sorted = sortBrowserSearchResults([pinnedOld, unpinned, pinnedNew])
    #expect(sorted.map(\.url) == [
        "https://new.example.com",
        "https://old.example.com",
        "https://unpinned.example.com"
    ])
}

@Test func allQuickOpenTabsRetainsActiveTabs() async throws {
    let now = Date()
    let activePinnedTab = BrowserSearchResult(
        title: "Active Pinned",
        url: "https://active-pinned.example.com",
        browserName: "Google Chrome",
        type: .tab,
        timestamp: now,
        isCurrentFlowActiveTab: true,
        isPinned: true
    )
    let activeUnpinnedTab = BrowserSearchResult(
        title: "Active Unpinned",
        url: "https://active-unpinned.example.com",
        browserName: "Google Chrome",
        type: .tab,
        timestamp: now,
        isCurrentFlowActiveTab: true,
        isPinned: false
    )
    let otherTab = BrowserSearchResult(
        title: "Other Tab",
        url: "https://other.example.com",
        browserName: "Google Chrome",
        type: .tab,
        timestamp: now.addingTimeInterval(-100),
        isCurrentFlowActiveTab: false,
        isPinned: false
    )

    let quickOpen = allQuickOpenTabs(from: [activePinnedTab, activeUnpinnedTab, otherTab])
    #expect(quickOpen.contains(where: { $0.url == "https://active-pinned.example.com" }))
    #expect(quickOpen.contains(where: { $0.url == "https://active-unpinned.example.com" }))
    #expect(quickOpen.contains(where: { $0.url == "https://other.example.com" }))
    #expect(quickOpen.first?.url == "https://active-pinned.example.com")
}

@Test func deduplicatingSamePagesPrefersPinnedTabOverUnpinnedTab() async throws {
    let now = Date()
    let unpinnedTab = BrowserSearchResult(
        title: "Shared Page",
        url: "https://example.com/shared",
        browserName: "Google Chrome",
        type: .tab,
        timestamp: now,
        isPinned: false
    )
    let pinnedTab = BrowserSearchResult(
        title: "Shared Page",
        url: "https://example.com/shared",
        browserName: "Google Chrome",
        type: .tab,
        timestamp: now.addingTimeInterval(-3_600),
        isPinned: true
    )

    let deduped = deduplicatingSamePages([unpinnedTab, pinnedTab]) { _ in 0 }
    #expect(deduped.count == 1)
    #expect(deduped.first?.isPinned == true)
}

@Test func deduplicatingSamePagesCollapsesDuplicateTabsWithLeadingCountBadges() async throws {
    let now = Date()
    let pinnedNotion = BrowserSearchResult(
        title: "(9+) Engineering AI Adoption Framework — Squad Capability Ladder",
        url: "https://app.notion.com/p/sevensystem/Engineering-AI-Adoption-Framework?t=38212269734a8069a48600a96b155008",
        browserName: "Microsoft Edge",
        type: .tab,
        timestamp: now.addingTimeInterval(-100),
        isPinned: true
    )
    let unpinnedNotion = BrowserSearchResult(
        title: "Engineering AI Adoption Framework — Squad Capability Ladder",
        url: "https://app.notion.com/p/sevensystem/Engineering-AI-Adoption-Framework?t=3d912269734a80fd948400a98fb66b1c",
        browserName: "Microsoft Edge",
        type: .tab,
        timestamp: now,
        isPinned: false
    )

    let deduped = deduplicatingSamePages([unpinnedNotion, pinnedNotion]) { _ in 0 }
    #expect(deduped.count == 1)
    #expect(deduped.first?.isPinned == true)
    #expect(deduped.first?.title == "(9+) Engineering AI Adoption Framework — Squad Capability Ladder")
}

@Test func deduplicatingSamePagesCollapsesIdenticalLiveCanonicalURLs() async throws {
    let now = Date()
    let first = BrowserSearchResult(
        title: "send my youtube tabs to feed — OpenClaw",
        url: "http://127.0.0.1:18789/chat/main/b07ae87c",
        browserName: "Microsoft Edge",
        type: .tab,
        timestamp: now.addingTimeInterval(-50),
        tabID: 484803551
    )
    let second = BrowserSearchResult(
        title: "send my youtube tabs to feed — OpenClaw",
        url: "http://127.0.0.1:18789/chat/main/b07ae87c",
        browserName: "Microsoft Edge",
        type: .tab,
        timestamp: now,
        tabID: 484804868
    )

    let deduped = deduplicatingSamePages([first, second]) { _ in 0 }
    #expect(deduped.count == 1)
    #expect(deduped.first?.tabID == 484804868)
}

@Test func quickOpenVisibleTabsRetainsActiveTabs() async throws {
    let now = Date()
    let activePinnedTab = BrowserSearchResult(
        title: "Active Pinned",
        url: "https://active-pinned.example.com",
        browserName: "Google Chrome",
        type: .tab,
        timestamp: now,
        isCurrentFlowActiveTab: true,
        isPinned: true
    )
    let activeUnpinnedTab = BrowserSearchResult(
        title: "Active Unpinned",
        url: "https://active-unpinned.example.com",
        browserName: "Google Chrome",
        type: .tab,
        timestamp: now,
        isCurrentFlowActiveTab: true,
        isPinned: false
    )

    let visible = quickOpenVisibleTabs(from: [activePinnedTab, activeUnpinnedTab], limit: 5)
    #expect(visible.contains(where: { $0.url == "https://active-pinned.example.com" }))
    #expect(visible.contains(where: { $0.url == "https://active-unpinned.example.com" }))
}

@Test func overlayPinStatusPreservesNativeBrowserPinnedTabEvenWhenSlotWasUnpinned() async throws {
    let slot = OrderedTabSlot(
        slotID: UUID(),
        url: "https://example.com/pinned-in-browser",
        matchKey: "https://example.com/pinned-in-browser",
        title: "Pinned In Browser",
        browserName: "Google Chrome",
        profileName: nil,
        state: .live,
        boundTabID: 42,
        isPinned: false,
        confirmedInBrowser: true
    )

    let browserPinnedTab = BrowserSearchResult(
        title: "Pinned In Browser",
        url: "https://example.com/pinned-in-browser",
        browserName: "Google Chrome",
        type: .tab,
        timestamp: Date(),
        tabID: 42,
        isPinned: true
    )

    let overlaid = MyOrderStore.overlayPinStatus(on: [browserPinnedTab], using: [slot])
    #expect(overlaid.count == 1)
    #expect(overlaid[0].isPinned == true)
}

@Test func reconcileUpdatesSlotToPinnedWhenLiveTabIsPinnedInBrowser() async throws {
    let unpinnedSlot = OrderedTabSlot(
        slotID: UUID(),
        url: "https://example.com/test",
        matchKey: "https://example.com/test",
        title: "Test Tab",
        browserName: "Google Chrome",
        profileName: nil,
        state: .live,
        boundTabID: 99,
        isPinned: false,
        confirmedInBrowser: true
    )

    let pinnedInBrowserTab = BrowserSearchResult(
        title: "Test Tab",
        url: "https://example.com/test",
        browserName: "Google Chrome",
        type: .tab,
        timestamp: Date(),
        tabID: 99,
        isPinned: true
    )

    let (reconciled, _) = MyOrderReconciler.reconcile(
        currentSlots: [unpinnedSlot],
        liveTabs: [pinnedInBrowserTab],
        runningBrowsers: ["Google Chrome"],
        pendingCloses: []
    )

    #expect(reconciled.count == 1)
    #expect(reconciled[0].isPinned == true)
}

// MARK: - Ghost pinned tabs

@Test func sortBrowserSearchResultsPlacesGhostPinnedTabsInTopPriorityAboveUnpinnedTabsAndSentLinks() async throws {
    let now = Date()
    let livePinned = BrowserSearchResult(
        title: "Live Pinned",
        url: "https://live-pinned.example.com",
        browserName: "Google Chrome",
        type: .tab,
        timestamp: now.addingTimeInterval(-100),
        isPinned: true,
        isGhost: false
    )
    let ghostPinned = BrowserSearchResult(
        title: "Ghost Pinned",
        url: "https://ghost-pinned.example.com",
        browserName: "Google Chrome",
        type: .tab,
        timestamp: now,
        isPinned: true,
        isGhost: true
    )
    let sent = BrowserSearchResult(
        title: "Sent Link",
        url: "https://sent.example.com",
        browserName: "Google Chrome",
        type: .sent,
        timestamp: now.addingTimeInterval(10)
    )
    let unpinned = BrowserSearchResult(
        title: "Unpinned Tab",
        url: "https://unpinned.example.com",
        browserName: "Google Chrome",
        type: .tab,
        timestamp: now.addingTimeInterval(20),
        isPinned: false
    )
    let bookmark = BrowserSearchResult(
        title: "Bookmark",
        url: "https://bookmark.example.com",
        browserName: "Google Chrome",
        type: .bookmark,
        timestamp: now.addingTimeInterval(30)
    )
    let history = BrowserSearchResult(
        title: "History",
        url: "https://history.example.com",
        browserName: "Google Chrome",
        type: .history,
        timestamp: now.addingTimeInterval(40)
    )

    let sorted = sortBrowserSearchResults([history, bookmark, unpinned, sent, ghostPinned, livePinned])
    #expect(sorted.map(\.url) == [
        "https://live-pinned.example.com",
        "https://ghost-pinned.example.com",
        "https://sent.example.com",
        "https://unpinned.example.com",
        "https://bookmark.example.com",
        "https://history.example.com"
    ])
}

@Test func sortBrowserSearchResultsWithFrecencyPreservesGhostPinnedPriorityOverUnpinnedFrecency() async throws {
    let now = Date()
    let livePinned = BrowserSearchResult(
        title: "Live Pinned",
        url: "https://live-pinned.example.com",
        browserName: "Google Chrome",
        type: .tab,
        timestamp: now,
        isPinned: true,
        isGhost: false
    )
    let ghostPinned = BrowserSearchResult(
        title: "Ghost Pinned",
        url: "https://ghost-pinned.example.com",
        browserName: "Google Chrome",
        type: .tab,
        timestamp: now,
        isPinned: true,
        isGhost: true
    )
    let hotUnpinned = BrowserSearchResult(
        title: "Hot Unpinned",
        url: "https://hot-unpinned.example.com",
        browserName: "Google Chrome",
        type: .tab,
        timestamp: now,
        isPinned: false
    )

    let scoreLookup: (BrowserSearchResult) -> Double = { result in
        if result.url == "https://hot-unpinned.example.com" { return 100.0 }
        return 0.0
    }

    let sorted = sortBrowserSearchResults([hotUnpinned, ghostPinned, livePinned], frecencyScore: scoreLookup)
    #expect(sorted.map(\.url) == [
        "https://live-pinned.example.com",
        "https://ghost-pinned.example.com",
        "https://hot-unpinned.example.com"
    ])
}

@Test func deduplicatingSamePagesPrefersLivePinnedTabOverGhostPinnedTab() async throws {
    let now = Date()
    let livePinned = BrowserSearchResult(
        title: "My Docs",
        url: "https://docs.example.com/page",
        browserName: "Google Chrome",
        type: .tab,
        timestamp: now.addingTimeInterval(-100),
        isPinned: true,
        isGhost: false
    )
    let ghostPinned = BrowserSearchResult(
        title: "My Docs",
        url: "https://docs.example.com/page",
        browserName: "Google Chrome",
        type: .tab,
        timestamp: now,
        isPinned: true,
        isGhost: true
    )

    let deduped = deduplicatingSamePages([ghostPinned, livePinned]) { _ in 0 }
    #expect(deduped.count == 1)
    #expect(deduped.first?.isGhost == false)
}

@Test func deduplicatingSamePagesPrefersGhostPinnedTabOverHistoryAndBookmark() async throws {
    let now = Date()
    let ghostPinned = BrowserSearchResult(
        title: "My Docs",
        url: "https://docs.example.com/page",
        browserName: "Google Chrome",
        type: .tab,
        timestamp: now.addingTimeInterval(-100),
        isPinned: true,
        isGhost: true
    )
    let history = BrowserSearchResult(
        title: "My Docs",
        url: "https://docs.example.com/page",
        browserName: "Google Chrome",
        type: .history,
        timestamp: now
    )
    let bookmark = BrowserSearchResult(
        title: "My Docs",
        url: "https://docs.example.com/page",
        browserName: "Google Chrome",
        type: .bookmark,
        timestamp: now
    )

    let deduped = deduplicatingSamePages([history, bookmark, ghostPinned]) { _ in 0 }
    #expect(deduped.count == 1)
    #expect(deduped.first?.isGhost == true)
    #expect(deduped.first?.type == .tab)
}

@Test func orderedTabSlotAsSearchResultReflectsGhostState() async throws {
    let slotID = UUID()
    let liveSlot = OrderedTabSlot(
        slotID: slotID,
        url: "https://example.com/tab",
        matchKey: "https://example.com/tab",
        title: "Tab",
        browserName: "Google Chrome",
        profileName: nil,
        state: .live,
        boundTabID: 10,
        isPinned: true,
        confirmedInBrowser: true
    )
    let ghostSlot = OrderedTabSlot(
        slotID: slotID,
        url: "https://example.com/tab",
        matchKey: "https://example.com/tab",
        title: "Tab",
        browserName: "Google Chrome",
        profileName: nil,
        state: .ghost,
        boundTabID: nil,
        isPinned: true,
        confirmedInBrowser: true
    )

    let liveResult = liveSlot.asSearchResult
    let ghostResult = ghostSlot.asSearchResult

    #expect(liveResult.isGhost == false)
    #expect(ghostResult.isGhost == true)
    #expect(ghostResult.id.contains("ghost"))
}

@Test func normalizeURLAndCanonicalURLPreserveNonStandardPorts() async throws {
    let port3000 = Frecency.normalizeURL("http://localhost:3000/app")
    let port8080 = Frecency.normalizeURL("http://localhost:8080/app")
    let portStandard = Frecency.normalizeURL("http://localhost:80/app")

    #expect(port3000 == "http://localhost:3000/app")
    #expect(port8080 == "http://localhost:8080/app")
    #expect(portStandard == "http://localhost/app")
    #expect(MyOrderReconciler.canonicalURL("http://localhost:3000/app") != MyOrderReconciler.canonicalURL("http://localhost:8080/app"))
    #expect(MyOrderReconciler.urlsMatch("http://localhost:3000/app", "http://localhost:8080/app") == false)
}

