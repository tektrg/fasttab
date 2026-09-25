import Foundation
import Testing
@testable import FastTab

// MARK: - annotatingPinnedAudibleTabs grace window

@Test func annotatingPinnedAudibleTabsStampsRawlyAudibleTab() async throws {
    let now = Date()
    let audibleTab = BrowserSearchResult(
        title: "Now playing",
        url: "https://open.spotify.com/track/abc",
        browserName: "Google Chrome",
        type: .tab,
        timestamp: now,
        isPinnedAudibleTab: true
    )

    var lastSeenAt: [String: Date] = [:]
    let annotated = annotatingPinnedAudibleTabs([audibleTab], lastAudibleSeenAt: &lastSeenAt, now: now)

    #expect(annotated.first?.isPinnedAudibleTab == true)
    #expect(lastSeenAt[audibleTab.tabRecencyKey!] == now)
}

@Test func annotatingPinnedAudibleTabsStaysStickyThroughBriefSilence() async throws {
    let start = Date()
    let quietMoment = start.addingTimeInterval(10) // within the 15s grace window

    let goneSilentTab = BrowserSearchResult(
        title: "Now playing",
        url: "https://open.spotify.com/track/abc",
        browserName: "Google Chrome",
        type: .tab,
        timestamp: quietMoment,
        isPinnedAudibleTab: false // no longer audible this instant
    )

    var lastSeenAt: [String: Date] = [goneSilentTab.tabRecencyKey!: start]
    let annotated = annotatingPinnedAudibleTabs([goneSilentTab], lastAudibleSeenAt: &lastSeenAt, now: quietMoment)

    #expect(annotated.first?.isPinnedAudibleTab == true)
}

@Test func annotatingPinnedAudibleTabsUnpinsAfterGraceWindowExpires() async throws {
    let start = Date()
    let longAfterSoundStopped = start.addingTimeInterval(20) // past the 15s grace window

    let staleTab = BrowserSearchResult(
        title: "Now playing",
        url: "https://open.spotify.com/track/abc",
        browserName: "Google Chrome",
        type: .tab,
        timestamp: longAfterSoundStopped,
        isPinnedAudibleTab: false
    )

    var lastSeenAt: [String: Date] = [staleTab.tabRecencyKey!: start]
    let annotated = annotatingPinnedAudibleTabs([staleTab], lastAudibleSeenAt: &lastSeenAt, now: longAfterSoundStopped)

    #expect(annotated.first?.isPinnedAudibleTab == false)
}

@Test func annotatingPinnedAudibleTabsLeavesNeverHeardTabUnflagged() async throws {
    let now = Date()
    let neverHeard = BrowserSearchResult(
        title: "Quiet tab",
        url: "https://example.com/notes",
        browserName: "Google Chrome",
        type: .tab,
        timestamp: now,
        isPinnedAudibleTab: false
    )

    var lastSeenAt: [String: Date] = [:]
    let annotated = annotatingPinnedAudibleTabs([neverHeard], lastAudibleSeenAt: &lastSeenAt, now: now)

    #expect(annotated.first?.isPinnedAudibleTab == false)
}
