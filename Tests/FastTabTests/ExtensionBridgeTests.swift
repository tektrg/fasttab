import Foundation
import Testing
@testable import FastTab

// Serialized: the decorator tests flip `ExtensionBetaPreference`, a global
// UserDefaults value, so they must not run concurrently.
@Suite(.serialized) struct ExtensionBridgeTests {

    // MARK: - Test doubles

    private final class MockBridge: ExtensionBridgeServing, @unchecked Sendable {
        var view: ExtensionSnapshotView?
        var commandResult: Bool = false
        var lastCommand: (app: String, type: String, tabID: Int, extraPayload: [String: Bool])?

        func snapshotView(for appName: String, profileCount: Int) -> ExtensionSnapshotView? { view }
        func isConnected(appName: String) -> Bool { view != nil }
        func sendCommand(appName: String, type: String, tabID: Int, extraPayload: [String: Any], timeout: TimeInterval) -> Bool {
            var boolPayload: [String: Bool] = [:]
            for (k, v) in extraPayload { if let b = v as? Bool { boolPayload[k] = b } }
            lastCommand = (appName, type, tabID, boolPayload)
            return commandResult
        }
    }

    private final class RecordingBackend: BrowserBackend, ChromiumProfileAccess, @unchecked Sendable {
        var activateCalls = 0
        var closeCalls = 0
        var fetchLiveTabsCalls = 0
        var pollCalls = 0

        var appName: String { "Google Chrome" }
        var bundleIdentifier: String { "com.google.Chrome" }
        func profileCount() -> Int { 0 }
        func chromiumProfiles() -> [ChromiumProfile] { [] }

        func fetchLiveTabs(fetchStart: Date, activeTimes: inout [String: Date], currentFlowSourceAppBundleIdentifier: String?) -> [BrowserSearchResult] {
            fetchLiveTabsCalls += 1
            return []
        }
        func pollActiveTabKeys() -> [String] { pollCalls += 1; return [] }
        func fetchAllBookmarks() -> [BrowserSearchResult] { [] }
        func fetchRecentHistory(perBrowserLimit: Int) -> [BrowserSearchResult] { [] }
        func searchHistory(query: String, limit: Int) -> [BrowserSearchResult] { [] }
        func fetchFaviconData(pageURL: String) -> Data? { nil }
        func activateTab(_ result: BrowserSearchResult) { activateCalls += 1 }
        func closeTab(_ result: BrowserSearchResult) { closeCalls += 1 }
        func closeTabWithResult(_ result: BrowserSearchResult, allowPositionalFallback: Bool) -> TabCloseResult { closeCalls += 1; return .closed }
        func openURL(_ result: BrowserSearchResult) {}
        func deleteBookmark(_ result: BrowserSearchResult) -> Bool { false }
        func deleteHistoryItem(_ result: BrowserSearchResult) {}
    }

    private func makeTab(id: Int, windowIndex: Int, tabIndex: Int, title: String, url: String, active: Bool = false, audible: Bool = false, discarded: Bool = false, groupTitle: String? = nil) -> ExtensionTabRecord {
        ExtensionTabRecord(
            tabID: id,
            windowIndex: windowIndex,
            tabIndex: tabIndex,
            title: title,
            url: url,
            windowName: "",
            isActive: active,
            isAudible: audible,
            isMuted: false,
            isPinned: false,
            isDiscarded: discarded,
            groupTitle: groupTitle
        )
    }

    // MARK: - Wire decoding

    @Test func decodeTabMapsExtensionFields() {
        let dict: [String: Any] = [
            "id": 42, "windowId": 7, "windowIndex": 1, "tabIndex": 3,
            "title": "Notion", "url": "https://notion.so/x", "windowName": "Work",
            "active": true, "audible": true, "muted": false, "pinned": false,
            "discarded": false, "groupTitle": "Deep work"
        ]
        let tab = ExtensionBridge.decodeTab(dict)
        #expect(tab?.tabID == 42)
        #expect(tab?.windowIndex == 1)
        #expect(tab?.tabIndex == 3)
        #expect(tab?.title == "Notion")
        #expect(tab?.isActive == true)
        #expect(tab?.isAudible == true)
        #expect(tab?.groupTitle == "Deep work")
    }

    @Test func decodeTabRejectsMissingIDOrEmptyURL() {
        #expect(ExtensionBridge.decodeTab(["url": "https://x.com"]) == nil)
        #expect(ExtensionBridge.decodeTab(["id": 1, "url": ""]) == nil)
    }

    @Test func decodeHelloMapsBrowserApp() {
        let hello = ExtensionBridge.decodeInboundMessage(type: "hello", payload: ["app": "brave", "extensionVersion": "0.1.0"], now: Date())
        guard case .hello(let appName, let version) = hello else {
            Issue.record("expected hello")
            return
        }
        #expect(appName == "Brave Browser")
        #expect(version == "0.1.0")
    }

    @Test func decodeSnapshotCollectsTabs() {
        let snapshot = ExtensionBridge.decodeInboundMessage(
            type: "snapshot",
            payload: ["tabs": [["id": 1, "url": "https://a.com", "title": "A"]]],
            now: Date()
        )
        guard case .snapshot(let tabs) = snapshot else {
            Issue.record("expected snapshot")
            return
        }
        #expect(tabs.count == 1)
        #expect(tabs[0].tabID == 1)
    }

    @Test func decodeUnknownTypeIsContactOnly() {
        let msg = ExtensionBridge.decodeInboundMessage(type: "pong", payload: [:], now: Date())
        guard case .contactOnly = msg else {
            Issue.record("expected contactOnly")
            return
        }
    }

    // MARK: - Wire framing

    @Test func readFrameStripsNativeMessagingLengthPrefix() throws {
        let pipe = Pipe()
        defer {
            try? pipe.fileHandleForWriting.close()
            try? pipe.fileHandleForReading.close()
        }

        let json = Data(#"{"v":1,"type":"hello","seq":1,"payload":{"app":"chrome"}}"#.utf8)
        var length = UInt32(json.count).littleEndian
        var framed = Data()
        withUnsafeBytes(of: &length) { framed.append(contentsOf: $0) }
        framed.append(json)
        try pipe.fileHandleForWriting.write(contentsOf: framed)

        let result = ExtensionBridge.readFrame(fd: pipe.fileHandleForReading.fileDescriptor)
        #expect(result == json)
        let parsed = try #require(JSONSerialization.jsonObject(with: result ?? Data()) as? [String: Any])
        #expect(parsed["type"] as? String == "hello")
    }

    // MARK: - Activation events (drives frecency ranking)

    @Test func activationEventCarriesAppNameAndTabURL() {
        let tab = makeTab(id: 42, windowIndex: 1, tabIndex: 1, title: "Notion", url: "https://notion.so/x")
        let at = Date()
        let event = ExtensionBridge.activationEvent(appName: "Google Chrome", tabs: [42: tab], tabID: 42, at: at)
        #expect(event?.appName == "Google Chrome")
        #expect(event?.url == "https://notion.so/x")
        #expect(event?.at == at)
    }

    @Test func activationEventNilBeforeHelloNamesTheConnection() {
        let tab = makeTab(id: 42, windowIndex: 1, tabIndex: 1, title: "Notion", url: "https://notion.so/x")
        let event = ExtensionBridge.activationEvent(appName: "", tabs: [42: tab], tabID: 42, at: Date())
        #expect(event == nil)
    }

    @Test func activationEventNilWhenTabNotYetInSnapshot() {
        let event = ExtensionBridge.activationEvent(appName: "Google Chrome", tabs: [:], tabID: 42, at: Date())
        #expect(event == nil)
    }

    // MARK: - Snapshot merge

    @Test func applySnapshotReplacesTabsAndPrunesActivationTimes() {
        var connection = ConnectionState()
        let tabA = makeTab(id: 1, windowIndex: 1, tabIndex: 1, title: "A", url: "https://a.com", active: true)
        let tabB = makeTab(id: 2, windowIndex: 1, tabIndex: 2, title: "B", url: "https://b.com")
        connection.tabs = [1: tabA, 2: tabB]
        connection.activationTimes = [1: Date(), 2: Date()]

        ExtensionBridge.applySnapshot(&connection, tabs: [tabA])

        #expect(connection.tabs.count == 1)
        #expect(connection.tabs[1] != nil)
        #expect(connection.activationTimes[1] != nil)
        #expect(connection.activationTimes[2] == nil)
    }

    @Test func dedupedTabsCollapsesSameTabReportedByTwoRacingConnections() {
        // Reproduces a service-worker restart: the old connection's read loop
        // hasn't noticed EOF yet, so the same physical tab (same tabID, same
        // URL) briefly appears in two connections' snapshots.
        let tab = makeTab(id: 1, windowIndex: 1, tabIndex: 1, title: "A", url: "https://a.com")

        let tabs = ExtensionBridge.dedupedTabs(from: [[tab], [tab]])

        #expect(tabs.count == 1)
    }

    @Test func dedupedTabsKeepsDistinctTabsFromDifferentProfilesThatReuseATabID() {
        // Different profiles have independent tabID namespaces, so the same
        // raw tabID can legitimately point at two different real tabs. Only
        // (tabID, url) together identify "the same tab" — never tabID alone.
        let tabFromProfileA = makeTab(id: 1, windowIndex: 1, tabIndex: 1, title: "A", url: "https://a.com")
        let tabFromProfileB = makeTab(id: 1, windowIndex: 1, tabIndex: 1, title: "B", url: "https://b.com")

        let tabs = ExtensionBridge.dedupedTabs(from: [[tabFromProfileA], [tabFromProfileB]])

        #expect(tabs.count == 2)
    }

    @Test func dedupedTabsCollapsesOneTabReportedUnderTwoIDsAfterATabIDSwap() {
        // Reproduces the false `@duplicate` hit: Chromium swapped this tab's ID
        // (waking a sleeping tab / prerender activation), the extension's mirror
        // kept the pre-swap ID, so one physical tab arrives twice — same window
        // slot, same URL, different IDs, the stale copy still marked discarded.
        let staleAfterIDSwap = makeTab(id: 41, windowIndex: 1, tabIndex: 3, title: "Roadmap", url: "https://notion.so/x", discarded: true)
        let live = makeTab(id: 88, windowIndex: 1, tabIndex: 3, title: "(9+) Roadmap", url: "https://notion.so/x")

        let tabs = ExtensionBridge.dedupedTabs(from: [[staleAfterIDSwap, live]])

        #expect(tabs.count == 1)
        #expect(tabs.first?.tabID == 88)
        #expect(tabs.first?.isDiscarded == false)
    }

    @Test func dedupedTabsKeepsTwoRealTabsShowingTheSamePageInDifferentSlots() {
        // The user really does have the same page open twice — different window
        // slots, so both are real and `@duplicate` should report them.
        let first = makeTab(id: 1, windowIndex: 1, tabIndex: 3, title: "Roadmap", url: "https://notion.so/x")
        let second = makeTab(id: 2, windowIndex: 1, tabIndex: 9, title: "Roadmap", url: "https://notion.so/x")

        let tabs = ExtensionBridge.dedupedTabs(from: [[first, second]])

        #expect(tabs.count == 2)
    }

    @Test func dedupedTabsKeepsSameSlotTabsFromDifferentProfiles() {
        // `windowIndex` is numbered per profile, so slot 1/1 in two profiles is
        // two different windows — collapsing them would hide a real tab.
        let profileA = makeTab(id: 1, windowIndex: 1, tabIndex: 1, title: "Inbox", url: "https://mail.example.com")
        let profileB = makeTab(id: 2, windowIndex: 1, tabIndex: 1, title: "Inbox", url: "https://mail.example.com")

        let tabs = ExtensionBridge.dedupedTabs(from: [[profileA], [profileB]])

        #expect(tabs.count == 2)
    }

    @Test func dedupedTabsKeepsStaleRecordWhoseSlotNowHoldsADifferentPage() {
        // Same slot, different URL: the second record is a different tab (or the
        // same slot after a real navigation), so neither may be dropped —
        // dropping one here would hide a tab from the user.
        let earlier = makeTab(id: 1, windowIndex: 1, tabIndex: 2, title: "Docs", url: "https://a.example.com")
        let later = makeTab(id: 2, windowIndex: 1, tabIndex: 2, title: "Mail", url: "https://b.example.com")

        let tabs = ExtensionBridge.dedupedTabs(from: [[earlier, later]])

        #expect(tabs.count == 2)
    }

    @Test func freshestConnectionsKeepsOnlyMostRecentWhenOverProfileCount() {
        // Reproduces a stale connection that outlives its process teardown
        // (e.g. system sleep/wake) and lingers alongside the real one — both
        // still within `freshWindow`, so the count-based gate alone can't
        // tell them apart. Only the most recently contacted connection (the
        // real one) should survive when there's exactly one known profile.
        var stale = ConnectionState()
        stale.appName = "Google Chrome"
        stale.lastContactAt = Date().addingTimeInterval(-70)
        stale.tabs = [1: makeTab(id: 1, windowIndex: 1, tabIndex: 1, title: "Stale", url: "https://stale.example.com")]

        var fresh = ConnectionState()
        fresh.appName = "Google Chrome"
        fresh.lastContactAt = Date()
        fresh.tabs = [1: makeTab(id: 1, windowIndex: 1, tabIndex: 1, title: "Fresh", url: "https://fresh.example.com")]

        let kept = ExtensionBridge.freshestConnections([stale, fresh], limit: 1)

        #expect(kept.count == 1)
        #expect(kept.first?.tabs[1]?.url == "https://fresh.example.com")
    }

    @Test func freshestConnectionsLeavesConnectionsUncappedWhenWithinProfileCount() {
        let a = ConnectionState()
        let b = ConnectionState()

        let kept = ExtensionBridge.freshestConnections([a, b], limit: 2)

        #expect(kept.count == 2)
    }

    @Test func freshestConnectionsUncappedWhenProfileCountUnreliable() {
        let a = ConnectionState()
        let b = ConnectionState()

        let kept = ExtensionBridge.freshestConnections([a, b], limit: 0)

        #expect(kept.count == 2)
    }

    // MARK: - Serve/reject gate

    private func connection(ageSecs: TimeInterval, now: Date, url: String = "https://example.com") -> ConnectionState {
        var connection = ConnectionState()
        connection.appName = "Microsoft Edge"
        connection.lastContactAt = now.addingTimeInterval(-ageSecs)
        connection.tabs = [1: makeTab(id: 1, windowIndex: 1, tabIndex: 1, title: "T", url: url)]
        return connection
    }

    @Test func gateServesWhenGhostConnectionOutlivesItsProfile() {
        // The real-world stall: a closed profile's socket stays open (the relay
        // process outlives the profile, so no EOF) and its age climbs forever.
        // Checking freshness across *all* connections rejected permanently;
        // the ghost must be dropped as an extra connection first.
        let now = Date()
        let ghost = connection(ageSecs: 1856, now: now, url: "https://ghost.example.com")
        let live = connection(ageSecs: 4, now: now, url: "https://live.example.com")

        let decision = ExtensionBridge.servableConnections(
            [ghost, live], profileCount: 1, freshWindow: 90, now: now
        )

        guard case .serve(let kept, let droppedGhosts) = decision else {
            Issue.record("expected serve, got \(decision)")
            return
        }
        #expect(kept.count == 1)
        #expect(droppedGhosts == 1)
        #expect(kept.first?.tabs[1]?.url == "https://live.example.com")
    }

    @Test func gateRejectsWhenAGenuineProfileIsStale() {
        // Two profiles, two connections, one genuinely suspended — nothing to
        // drop here, so serving would hide that profile's tabs. Must reject.
        let now = Date()
        let stale = connection(ageSecs: 480, now: now)
        let live = connection(ageSecs: 2, now: now)

        let decision = ExtensionBridge.servableConnections(
            [stale, live], profileCount: 2, freshWindow: 90, now: now
        )

        guard case .reject = decision else {
            Issue.record("expected reject, got \(decision)")
            return
        }
    }

    @Test func gateRejectsWhenFewerConnectionsThanProfiles() {
        let now = Date()

        let decision = ExtensionBridge.servableConnections(
            [connection(ageSecs: 1, now: now)], profileCount: 2, freshWindow: 90, now: now
        )

        guard case .reject = decision else {
            Issue.record("expected reject, got \(decision)")
            return
        }
    }

    @Test func gateRejectsProtocolMismatch() {
        let now = Date()
        var mismatched = connection(ageSecs: 1, now: now)
        mismatched.isProtocolMismatch = true

        let decision = ExtensionBridge.servableConnections(
            [mismatched], profileCount: 1, freshWindow: 90, now: now
        )

        guard case .reject = decision else {
            Issue.record("expected reject, got \(decision)")
            return
        }
    }

    @Test func gateRejectsWhenNoConnections() {
        let decision = ExtensionBridge.servableConnections(
            [], profileCount: 1, freshWindow: 90, now: Date()
        )

        guard case .reject = decision else {
            Issue.record("expected reject, got \(decision)")
            return
        }
    }

    // MARK: - Sequence-gap detection

    @Test func seqGapRequestsResnapshot() {
        #expect(ExtensionBridge.shouldRequestResnapshot(lastSeq: 5, incomingSeq: 7, type: "tabUpdated") == true)
        #expect(ExtensionBridge.shouldRequestResnapshot(lastSeq: 5, incomingSeq: 6, type: "tabUpdated") == false)
        #expect(ExtensionBridge.shouldRequestResnapshot(lastSeq: 0, incomingSeq: 3, type: "tabUpdated") == false)
        #expect(ExtensionBridge.shouldRequestResnapshot(lastSeq: 5, incomingSeq: 9, type: "snapshot") == false)
        #expect(ExtensionBridge.shouldRequestResnapshot(lastSeq: 5, incomingSeq: 9, type: "commandResult") == false)
    }

    // MARK: - Decorator selection

    @Test func fetchLiveTabsUsesExtensionSnapshotWhenEnabledAndServable() {
        ExtensionBetaPreference.setEnabled(true)
        defer { ExtensionBetaPreference.setEnabled(false) }

        let now = Date()
        let bridge = MockBridge()
        bridge.view = ExtensionSnapshotView(
            tabs: [makeTab(id: 42, windowIndex: 1, tabIndex: 2, title: "Notion", url: "https://notion.so/x", active: true, groupTitle: "Deep work")],
            activationTimes: [42: now.addingTimeInterval(-60)]
        )
        let recording = RecordingBackend()
        let backend = ExtensionBackedBackend(inner: recording, bridge: bridge)

        var activeTimes: [String: Date] = [:]
        let results = backend.fetchLiveTabs(
            fetchStart: now,
            activeTimes: &activeTimes,
            currentFlowSourceAppBundleIdentifier: "com.google.Chrome"
        )

        #expect(recording.fetchLiveTabsCalls == 0) // extension path, no AppleScript
        #expect(results.count == 1)
        #expect(results[0].tabID == 42)
        #expect(results[0].tabGroupTitle == "Deep work")
        #expect(results[0].isCurrentFlowActiveTab == true)
        #expect(activeTimes["Google Chrome|1|2|https://notion.so/x"] != nil)
    }

    @Test func fetchLiveTabsFallsBackWhenBetaOff() {
        ExtensionBetaPreference.setEnabled(false)
        defer { ExtensionBetaPreference.setEnabled(false) }

        let bridge = MockBridge()
        bridge.view = ExtensionSnapshotView(tabs: [makeTab(id: 1, windowIndex: 1, tabIndex: 1, title: "A", url: "https://a.com")], activationTimes: [:])
        let recording = RecordingBackend()
        let backend = ExtensionBackedBackend(inner: recording, bridge: bridge)

        var activeTimes: [String: Date] = [:]
        _ = backend.fetchLiveTabs(fetchStart: Date(), activeTimes: &activeTimes, currentFlowSourceAppBundleIdentifier: nil)

        #expect(recording.fetchLiveTabsCalls == 1)
    }

    @Test func fetchLiveTabsFallsBackWhenDisconnected() {
        ExtensionBetaPreference.setEnabled(true)
        defer { ExtensionBetaPreference.setEnabled(false) }

        let bridge = MockBridge()
        bridge.view = nil // not connected / stale
        let recording = RecordingBackend()
        let backend = ExtensionBackedBackend(inner: recording, bridge: bridge)

        var activeTimes: [String: Date] = [:]
        _ = backend.fetchLiveTabs(fetchStart: Date(), activeTimes: &activeTimes, currentFlowSourceAppBundleIdentifier: nil)

        #expect(recording.fetchLiveTabsCalls == 1)
    }

    @Test func pollUsesFrontWindowActiveTabFromSnapshot() {
        ExtensionBetaPreference.setEnabled(true)
        defer { ExtensionBetaPreference.setEnabled(false) }

        let bridge = MockBridge()
        bridge.view = ExtensionSnapshotView(
            tabs: [
                makeTab(id: 1, windowIndex: 1, tabIndex: 2, title: "Front", url: "https://front.com", active: true),
                makeTab(id: 2, windowIndex: 2, tabIndex: 1, title: "Other", url: "https://other.com", active: true)
            ],
            activationTimes: [:]
        )
        let recording = RecordingBackend()
        let backend = ExtensionBackedBackend(inner: recording, bridge: bridge)

        let keys = backend.pollActiveTabKeys()

        #expect(recording.pollCalls == 0)
        #expect(keys == ["Google Chrome|1|2|https://front.com", "Google Chrome|https://front.com"])
    }

    // MARK: - Tab actions

    @Test func activateTabUsesStableIDWhenServable() {
        ExtensionBetaPreference.setEnabled(true)
        defer { ExtensionBetaPreference.setEnabled(false) }

        let bridge = MockBridge()
        bridge.view = ExtensionSnapshotView(tabs: [], activationTimes: [:])
        bridge.commandResult = true
        let recording = RecordingBackend()
        let backend = ExtensionBackedBackend(inner: recording, bridge: bridge)

        let result = BrowserSearchResult(
            title: "Notion", url: "https://notion.so/x",
            browserName: "Google Chrome", type: .tab, timestamp: Date(), tabID: 42
        )
        backend.activateTab(result)

        #expect(bridge.lastCommand?.type == "activateTab")
        #expect(bridge.lastCommand?.tabID == 42)
        #expect(recording.activateCalls == 0)
    }

    @Test func activateTabFallsBackWhenNoTabID() {
        ExtensionBetaPreference.setEnabled(false)
        defer { ExtensionBetaPreference.setEnabled(false) }

        let bridge = MockBridge()
        let recording = RecordingBackend()
        let backend = ExtensionBackedBackend(inner: recording, bridge: bridge)

        let result = BrowserSearchResult(
            title: "Notion", url: "https://notion.so/x",
            browserName: "Google Chrome", type: .tab, timestamp: Date()
        )
        backend.activateTab(result)

        #expect(bridge.lastCommand == nil)
        #expect(recording.activateCalls == 1)
    }

    @Test func closeTabFallsBackWhenExtensionCommandFails() {
        ExtensionBetaPreference.setEnabled(true)
        defer { ExtensionBetaPreference.setEnabled(false) }

        let bridge = MockBridge()
        bridge.view = ExtensionSnapshotView(tabs: [], activationTimes: [:])
        bridge.commandResult = false // extension refused → AppleScript fallback
        let recording = RecordingBackend()
        let backend = ExtensionBackedBackend(inner: recording, bridge: bridge)

        let result = BrowserSearchResult(
            title: "Notion", url: "https://notion.so/x",
            browserName: "Google Chrome", type: .tab, timestamp: Date(), tabID: 42
        )
        backend.closeTab(result)

        #expect(bridge.lastCommand?.type == "closeTab")
        #expect(recording.closeCalls == 1)
    }

    @Test func closeTabWithResultFallsBackToInnerWhenExtensionFailsWithoutPositionalFallback() {
        ExtensionBetaPreference.setEnabled(true)
        defer { ExtensionBetaPreference.setEnabled(false) }

        let bridge = MockBridge()
        bridge.view = ExtensionSnapshotView(tabs: [], activationTimes: [:])
        bridge.commandResult = false // extension failed
        let recording = RecordingBackend()
        let backend = ExtensionBackedBackend(inner: recording, bridge: bridge)

        let result = BrowserSearchResult(
            title: "Notion", url: "https://notion.so/x",
            browserName: "Google Chrome", type: .tab, timestamp: Date(), tabID: 42
        )
        let closeResult = backend.closeTabWithResult(result, allowPositionalFallback: false)

        #expect(bridge.lastCommand?.type == "closeTab")
        #expect(recording.closeCalls == 1)
        #expect(closeResult == .closed)
    }

    @Test func toggleMuteTabSendsSetMutedCommandWhenServable() {
        ExtensionBetaPreference.setEnabled(true)
        defer { ExtensionBetaPreference.setEnabled(false) }

        let bridge = MockBridge()
        bridge.view = ExtensionSnapshotView(tabs: [], activationTimes: [:])
        bridge.commandResult = true
        let recording = RecordingBackend()
        let backend = ExtensionBackedBackend(inner: recording, bridge: bridge)

        let result = BrowserSearchResult(
            title: "Notion", url: "https://notion.so/x",
            browserName: "Google Chrome", type: .tab, timestamp: Date(), tabID: 42
        )
        backend.toggleMuteTab(result, muted: true)

        #expect(bridge.lastCommand?.type == "setMuted")
        #expect(bridge.lastCommand?.tabID == 42)
        #expect(bridge.lastCommand?.extraPayload == ["muted": true])
    }

    @Test func toggleMuteTabNoOpsWithNoTabIDOrBetaOff() {
        ExtensionBetaPreference.setEnabled(false)
        defer { ExtensionBetaPreference.setEnabled(false) }

        let bridge = MockBridge()
        let recording = RecordingBackend()
        let backend = ExtensionBackedBackend(inner: recording, bridge: bridge)

        let result = BrowserSearchResult(
            title: "Notion", url: "https://notion.so/x",
            browserName: "Google Chrome", type: .tab, timestamp: Date(), tabID: 42
        )
        backend.toggleMuteTab(result, muted: true)

        #expect(bridge.lastCommand == nil)
    }

    @Test func togglePinTabSendsSetPinnedCommandWhenServable() {
        ExtensionBetaPreference.setEnabled(true)
        defer { ExtensionBetaPreference.setEnabled(false) }

        let bridge = MockBridge()
        bridge.commandResult = true
        let recording = RecordingBackend()
        let backend = ExtensionBackedBackend(inner: recording, bridge: bridge)

        let result = BrowserSearchResult(
            title: "GitHub", url: "https://github.com",
            browserName: "Google Chrome", type: .tab, timestamp: Date(), tabID: 77
        )
        backend.togglePinTab(result, pinned: true)

        let cmd = bridge.lastCommand
        #expect(cmd?.app == "Google Chrome")
        #expect(cmd?.type == "setPinned")
        #expect(cmd?.tabID == 77)
        #expect(cmd?.extraPayload["pinned"] == true)
    }

    @Test func togglePinTabNoOpsWithNoTabIDOrBetaOff() {
        ExtensionBetaPreference.setEnabled(false)
        defer { ExtensionBetaPreference.setEnabled(false) }

        let bridge = MockBridge()
        let recording = RecordingBackend()
        let backend = ExtensionBackedBackend(inner: recording, bridge: bridge)

        let result = BrowserSearchResult(
            title: "GitHub", url: "https://github.com",
            browserName: "Google Chrome", type: .tab, timestamp: Date(), tabID: 77
        )
        backend.togglePinTab(result, pinned: true)

        #expect(bridge.lastCommand == nil)
    }

    // MARK: - Native-host manifest

    @Test func installerManifestPinsOriginAndHostPath() throws {
        let data = try #require(NativeHostInstaller.manifestJSON(hostPath: "/Applications/FastTab.app/Contents/MacOS/FastTabNativeHost"))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(json["name"] as? String == "com.trungluong.fasttab")
        #expect(json["type"] as? String == "stdio")
        #expect(json["path"] as? String == "/Applications/FastTab.app/Contents/MacOS/FastTabNativeHost")
        #expect(json["allowed_origins"] as? [String] == ["chrome-extension://\(FastTabExtensionIdentity.id)/"])
    }

    @Test func dedupedTabsCollapsesWakingTabWithDifferentIDAndTabIndex() {
        let sleepingTab = makeTab(
            id: 484803551,
            windowIndex: 1,
            tabIndex: 34,
            title: "send my youtube tabs to feed — OpenClaw",
            url: "http://127.0.0.1:18789/chat/main/b07ae87c",
            discarded: true
        )
        let wakingTab = makeTab(
            id: 484804868,
            windowIndex: 1,
            tabIndex: 28,
            title: "send my youtube tabs to feed — OpenClaw",
            url: "http://127.0.0.1:18789/chat/main/b07ae87c",
            discarded: false
        )

        let deduped = ExtensionBridge.dedupedTabs(from: [[sleepingTab, wakingTab]])
        #expect(deduped.count == 1, "Sleeping tab and waking tab for same URL in same window must collapse even if tabID and tabIndex differ")
        #expect(deduped.first?.tabID == 484804868, "Waking/active tab should win over discarded tab")
    }
}
