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
