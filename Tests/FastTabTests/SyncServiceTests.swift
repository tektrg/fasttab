import Testing
import Foundation
import CloudKit
@testable import FastTab
import FastTabSync

@Suite("Mac-Side SyncService & SentLinkInbox")
struct SyncServiceTests {

    @Test("SentLinkInbox receive, search result mapping, and lifecycle")
    @MainActor
    func inboxReceiveAndMapping() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let fileURL = tempDir.appendingPathComponent("test_inbox.json")

        let inbox = SentLinkInbox(fileURL: fileURL)

        let payload = OpenOnMacPayload(url: "https://apple.com", title: "Apple Official", preferBrowser: "Safari")
        let payloadData = try JSONEncoder().encode(payload)
        let payloadJSON = String(data: payloadData, encoding: .utf8)!

        let command = SyncCommand(
            id: "cmd_123",
            kind: .openOnMac,
            targetDeviceID: "mac_1",
            sourceDeviceName: "Trung's iPhone",
            issuedAt: Date(),
            expiresAt: Date().addingTimeInterval(3600),
            payloadJSON: payloadJSON
        )

        inbox.receive(command: command)
        #expect(inbox.pendingCommands.count == 1)

        let results = inbox.asSearchResults()
        #expect(results.count == 1)
        #expect(results[0].title == "Apple Official")
        #expect(results[0].url == "https://apple.com")
        #expect(results[0].browserName == "Trung's iPhone")
        #expect(results[0].type == .sent)
        #expect(results[0].bookmarkID == "cmd_123")

        // Reload from disk to verify persistence
        let reloadedInbox = SentLinkInbox(fileURL: fileURL)
        #expect(reloadedInbox.pendingCommands.count == 1)

        // Mark opened
        let openedCmd = reloadedInbox.markOpened(commandID: "cmd_123")
        #expect(openedCmd != nil)
        #expect(openedCmd?.status == .done)
        #expect(reloadedInbox.pendingCommands.isEmpty)
        #expect(reloadedInbox.asSearchResults().isEmpty)

        // Clean up
        try? FileManager.default.removeItem(at: tempDir)
    }

    @Test("SentLinkInbox ignores expired commands")
    @MainActor
    func inboxExpiredCommands() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let fileURL = tempDir.appendingPathComponent("test_inbox_expired.json")

        let inbox = SentLinkInbox(fileURL: fileURL)

        let payload = OpenOnMacPayload(url: "https://expired.com", title: "Expired")
        let payloadData = try JSONEncoder().encode(payload)
        let payloadJSON = String(data: payloadData, encoding: .utf8)!

        let expiredCommand = SyncCommand(
            id: "cmd_expired",
            kind: .openOnMac,
            targetDeviceID: "mac_1",
            sourceDeviceName: "iPhone",
            issuedAt: Date().addingTimeInterval(-7200),
            expiresAt: Date().addingTimeInterval(-3600),
            payloadJSON: payloadJSON
        )

        inbox.receive(command: expiredCommand)
        #expect(inbox.pendingCommands.isEmpty)
        #expect(inbox.asSearchResults().isEmpty)

        // Clean up
        try? FileManager.default.removeItem(at: tempDir)
    }

    @Test("SentLinkInbox dismiss marks command refused")
    @MainActor
    func inboxDismiss() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let fileURL = tempDir.appendingPathComponent("test_inbox_dismiss.json")

        let inbox = SentLinkInbox(fileURL: fileURL)

        let payload = OpenOnMacPayload(url: "https://dismiss.com", title: "Dismiss Me")
        let payloadData = try JSONEncoder().encode(payload)
        let payloadJSON = String(data: payloadData, encoding: .utf8)!

        let command = SyncCommand(
            id: "cmd_dismiss",
            kind: .openOnMac,
            targetDeviceID: "mac_1",
            sourceDeviceName: "iPhone",
            issuedAt: Date(),
            expiresAt: Date().addingTimeInterval(3600),
            payloadJSON: payloadJSON
        )

        inbox.receive(command: command)
        #expect(inbox.pendingCommands.count == 1)

        let dismissed = inbox.dismiss(commandID: "cmd_dismiss")
        #expect(dismissed != nil)
        #expect(dismissed?.status == .refused)
        #expect(dismissed?.statusReason == "Dismissed on Mac")
        #expect(inbox.pendingCommands.isEmpty)

        // Clean up
        try? FileManager.default.removeItem(at: tempDir)
    }

    @Test("BrowserResultType.sent properties and sort hierarchy")
    func sentResultTypeProperties() {
        let sent = BrowserResultType.sent
        let tab = BrowserResultType.tab
        let bookmark = BrowserResultType.bookmark
        let history = BrowserResultType.history

        #expect(sent.sortPriority == -1)
        #expect(tab.sortPriority == 0)
        #expect(bookmark.sortPriority == 1)
        #expect(history.sortPriority == 2)

        #expect(sent.label == "From iPhone")
        #expect(sent.symbolName == "iphone.and.arrow.forward")
        #expect(sent.dimmingOpacity == 1.0)

        let now = Date()
        let sentResult = BrowserSearchResult(
            title: "Sent Link",
            url: "https://apple.com/sent",
            browserName: "iPhone",
            type: .sent,
            timestamp: now
        )
        let tabResult = BrowserSearchResult(
            title: "Open Tab",
            url: "https://apple.com/tab",
            browserName: "Safari",
            type: .tab,
            timestamp: now.addingTimeInterval(10)
        )
        let bookmarkResult = BrowserSearchResult(
            title: "Bookmark",
            url: "https://apple.com/bm",
            browserName: "Safari",
            type: .bookmark,
            timestamp: now.addingTimeInterval(20)
        )

        let sorted = sortBrowserSearchResults([bookmarkResult, tabResult, sentResult])
        #expect(sorted.count == 3)
        #expect(sorted[0].type == .sent)
        #expect(sorted[1].type == .tab)
        #expect(sorted[2].type == .bookmark)
    }

    @Test("SyncService sanitizeRecordName replaces invalid CloudKit characters")
    func sanitizeRecordName() {
        let raw = "MacBook Pro | Google Chrome / tab:123"
        let sanitized = SyncService.sanitizeRecordName(raw)
        #expect(!sanitized.contains("|"))
        #expect(!sanitized.contains("/"))
        #expect(!sanitized.contains(":"))
        #expect(!sanitized.contains(" "))
        #expect(sanitized == "MacBook_Pro___Google_Chrome___tab_123")
    }

    @Test("SyncService isIncognitoTab filtering")
    func incognitoFiltering() {
        let incognitoChromeTab = BrowserSearchResult(
            title: "Private Search",
            url: "https://duckduckgo.com",
            browserName: "Google Chrome",
            type: .tab,
            timestamp: Date(),
            windowName: "Incognito Window"
        )
        #expect(SyncService.isIncognitoTab(incognitoChromeTab) == true)

        let privateSafariTab = BrowserSearchResult(
            title: "Private Safari",
            url: "https://duckduckgo.com",
            browserName: "Safari",
            type: .tab,
            timestamp: Date(),
            windowName: "Private Browsing"
        )
        #expect(SyncService.isIncognitoTab(privateSafariTab) == true)

        let torTab = BrowserSearchResult(
            title: "Tor Search",
            url: "https://duckduckgo.com",
            browserName: "Brave",
            type: .tab,
            timestamp: Date(),
            windowName: "Private with Tor"
        )
        #expect(SyncService.isIncognitoTab(torTab) == true)

        let normalTab = BrowserSearchResult(
            title: "FastTab Documentation",
            url: "https://fasttab.app",
            browserName: "Google Chrome",
            type: .tab,
            timestamp: Date(),
            windowName: "FastTab — Work"
        )
        #expect(SyncService.isIncognitoTab(normalTab) == false)

        // Edge InPrivate
        let edgeInPrivate = BrowserSearchResult(
            title: "Edge Search",
            url: "https://bing.com",
            browserName: "Microsoft Edge",
            type: .tab,
            timestamp: Date(),
            windowName: "InPrivate Browsing"
        )
        #expect(SyncService.isIncognitoTab(edgeInPrivate) == true)

        // Orion Private
        let orionPrivate = BrowserSearchResult(
            title: "Orion Search",
            url: "https://kagi.com",
            browserName: "Orion",
            type: .tab,
            timestamp: Date(),
            windowName: "Private Window"
        )
        #expect(SyncService.isIncognitoTab(orionPrivate) == true)

        // Profile-level incognito flag
        let profilePrivate = BrowserSearchResult(
            title: "Chrome Tab",
            url: "https://google.com",
            browserName: "Google Chrome",
            type: .tab,
            timestamp: Date(),
            profileName: "Incognito Profile"
        )
        #expect(SyncService.isIncognitoTab(profilePrivate) == true)

        // Normal tab with 'private' in title or url must NOT be filtered out
        let normalTabWithPrivateWord = BrowserSearchResult(
            title: "Private Equity Today",
            url: "https://example.com/private-policy",
            browserName: "Safari",
            type: .tab,
            timestamp: Date(),
            windowName: "Main Window"
        )
        #expect(SyncService.isIncognitoTab(normalTabWithPrivateWord) == false)

        // Normal tab in a window whose active tab has words containing "tor" or "private"
        // (Chrome Web Store, History, Code Editor, GitHub Private Repo, Tutorial, Vector)
        let tabInStoreWindow = BrowserSearchResult(
            title: "FastTab Extension",
            url: "https://chromewebstore.google.com/detail/123",
            browserName: "Google Chrome",
            type: .tab,
            timestamp: Date(),
            windowName: "Chrome Web Store"
        )
        #expect(SyncService.isIncognitoTab(tabInStoreWindow) == false)

        let tabInHistoryWindow = BrowserSearchResult(
            title: "Swift Evolution",
            url: "https://github.com/swiftlang/swift-evolution",
            browserName: "Google Chrome",
            type: .tab,
            timestamp: Date(),
            windowName: "History of macOS - Wikipedia"
        )
        #expect(SyncService.isIncognitoTab(tabInHistoryWindow) == false)

        let tabInPrivateRepoWindow = BrowserSearchResult(
            title: "README.md",
            url: "https://github.com/myorg/private-repo",
            browserName: "Google Chrome",
            type: .tab,
            timestamp: Date(),
            windowName: "myorg/private-repo: Main backend"
        )
        #expect(SyncService.isIncognitoTab(tabInPrivateRepoWindow) == false)

        let tabInEditorWindow = BrowserSearchResult(
            title: "FastTab Workspace",
            url: "https://github.com/fasttab",
            browserName: "Safari",
            type: .tab,
            timestamp: Date(),
            windowName: "VS Code Editor - main.swift"
        )
        #expect(SyncService.isIncognitoTab(tabInEditorWindow) == false)

        // Trimming and whitespace edge cases
        let tabWithWhitespaceIncognito = BrowserSearchResult(
            title: "Private",
            url: "https://duckduckgo.com",
            browserName: "Safari",
            type: .tab,
            timestamp: Date(),
            windowName: "  Private Browsing  \n"
        )
        #expect(SyncService.isIncognitoTab(tabWithWhitespaceIncognito) == true)

        let tabWithWhitespaceProfile = BrowserSearchResult(
            title: "Private",
            url: "https://duckduckgo.com",
            browserName: "Google Chrome",
            type: .tab,
            timestamp: Date(),
            profileName: "  Incognito 2  "
        )
        #expect(SyncService.isIncognitoTab(tabWithWhitespaceProfile) == true)

        let tabWithNilNames = BrowserSearchResult(
            title: "Regular Page",
            url: "https://example.com",
            browserName: "Safari",
            type: .tab,
            timestamp: Date(),
            windowName: nil,
            profileName: nil
        )
        #expect(SyncService.isIncognitoTab(tabWithNilNames) == false)

        let tabInTorontoWindow = BrowserSearchResult(
            title: "Weather",
            url: "https://weather.com/toronto",
            browserName: "Safari",
            type: .tab,
            timestamp: Date(),
            windowName: "Toronto Weather - Forecast"
        )
        #expect(SyncService.isIncognitoTab(tabInTorontoWindow) == false)
    }

    @Test("SentLinkInbox recovers gracefully from corrupted inbox.json")
    @MainActor
    func inboxCorruptedFileRecovery() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = tempDir.appendingPathComponent("corrupted_inbox.json")

        // Write invalid JSON bytes
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        try "INVALID_GARBAGE_DATA".write(to: fileURL, atomically: true, encoding: .utf8)

        // SentLinkInbox should catch decode error, log, and recover with empty list
        let inbox = SentLinkInbox(fileURL: fileURL)
        #expect(inbox.pendingCommands.isEmpty)
        #expect(inbox.asSearchResults().isEmpty)

        // Saving new commands should cleanly overwrite the corrupted file
        let payload = OpenOnMacPayload(url: "https://recovered.com", title: "Recovered")
        let payloadData = try JSONEncoder().encode(payload)
        let payloadJSON = String(data: payloadData, encoding: .utf8)!

        let cmd = SyncCommand(
            id: "cmd_rec",
            kind: .openOnMac,
            targetDeviceID: "mac_1",
            sourceDeviceName: "iPhone",
            issuedAt: Date(),
            expiresAt: Date().addingTimeInterval(3600),
            payloadJSON: payloadJSON
        )
        inbox.receive(command: cmd)
        #expect(inbox.pendingCommands.count == 1)

        let reloaded = SentLinkInbox(fileURL: fileURL)
        #expect(reloaded.pendingCommands.count == 1)
        #expect(reloaded.pendingCommands.first?.id == "cmd_rec")

        // Clean up
        try? FileManager.default.removeItem(at: tempDir)
    }

    @Test("SentLinkInbox handles invalid payload JSON gracefully")
    @MainActor
    func inboxInvalidPayloadJSON() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = tempDir.appendingPathComponent("invalid_payload_inbox.json")

        let inbox = SentLinkInbox(fileURL: fileURL)

        // SyncCommand with malformed payloadJSON
        let malformedCommand = SyncCommand(
            id: "cmd_bad_payload",
            kind: .openOnMac,
            targetDeviceID: "mac_1",
            sourceDeviceName: "iPhone",
            issuedAt: Date(),
            expiresAt: Date().addingTimeInterval(3600),
            payloadJSON: "{ malformed json: true "
        )

        inbox.receive(command: malformedCommand)
        #expect(inbox.pendingCommands.count == 1)

        // asSearchResults should skip un-decodable payloads without crashing
        let results = inbox.asSearchResults()
        #expect(results.isEmpty)

        // Clean up
        try? FileManager.default.removeItem(at: tempDir)
    }

    @Test("SyncService tabContentFingerprint is stable under reorder but sensitive to tab changes")
    func tabContentFingerprint() {
        let tab1 = BrowserSearchResult(
            title: "GitHub",
            url: "https://github.com",
            browserName: "Safari",
            type: .tab,
            timestamp: Date(),
            tabID: 10
        )
        let tab2 = BrowserSearchResult(
            title: "Google",
            url: "https://google.com",
            browserName: "Google Chrome",
            type: .tab,
            timestamp: Date(),
            tabID: 20
        )

        let fp1 = SyncService.tabContentFingerprint([tab1, tab2])
        let fp2 = SyncService.tabContentFingerprint([tab2, tab1]) // reordered
        #expect(fp1 == fp2)

        let tab2Modified = BrowserSearchResult(
            title: "Google Search",
            url: "https://google.com",
            browserName: "Google Chrome",
            type: .tab,
            timestamp: Date(),
            tabID: 20
        )
        let fp3 = SyncService.tabContentFingerprint([tab1, tab2Modified])
        #expect(fp1 != fp3)
    }

    @Test("SyncService tabRecordName keys by tab ID on the extension path and by position on the fallback path")
    func tabRecordNameSchemes() {
        let extensionName = SyncService.tabRecordName(
            deviceID: "mac1",
            browserName: "Microsoft Edge",
            windowIndex: 1,
            tabIndex: 3,
            tabID: 484779784,
            fallbackIndex: 0
        )
        #expect(extensionName == "mac1_Microsoft_Edge_tab_484779784")

        let fallbackName = SyncService.tabRecordName(
            deviceID: "mac1",
            browserName: "Microsoft Edge",
            windowIndex: 2,
            tabIndex: 4,
            tabID: nil,
            fallbackIndex: 0
        )
        #expect(fallbackName == "mac1_Microsoft_Edge_win2_idx4")
    }

    @Test("SyncService tabRecordIDs maps a snapshot to the record IDs it would publish")
    func tabRecordIDsFromSnapshot() {
        let tab = BrowserSearchResult(
            title: "GitHub",
            url: "https://github.com",
            browserName: "Google Chrome",
            type: .tab,
            timestamp: Date(),
            tabID: 42
        )
        let ids = SyncService.tabRecordIDs(from: [tab], deviceID: "mac1")
        #expect(ids == Set([CKRecord.ID(recordName: "mac1_Google_Chrome_tab_42", zoneID: SyncConstants.stateZoneID)]))
    }

    @Test("SyncService multi-window tabRecordIDs produces collision-free CloudKit IDs across windows")
    func multiWindowTabRecordIDsCollisionFree() {
        // Simulating the user scenario: 77 tabs across 2 windows (18 tabs in Window 1, 59 tabs in Window 2)
        // 1. Extension path (with tabIDs)
        var extensionTabs: [BrowserSearchResult] = []
        for i in 1...18 {
            extensionTabs.append(BrowserSearchResult(
                title: "Window 1 Tab \(i)",
                url: "https://example.com/w1/t\(i)",
                browserName: "Google Chrome",
                type: .tab,
                timestamp: Date(),
                windowIndex: 1,
                tabIndex: i,
                tabID: 1000 + i
            ))
        }
        for i in 1...59 {
            extensionTabs.append(BrowserSearchResult(
                title: "Window 2 Tab \(i)",
                url: "https://example.com/w2/t\(i)",
                browserName: "Google Chrome",
                type: .tab,
                timestamp: Date(),
                windowIndex: 2,
                tabIndex: i,
                tabID: 2000 + i
            ))
        }
        #expect(extensionTabs.count == 77)
        let extensionRecordIDs = SyncService.tabRecordIDs(from: extensionTabs, deviceID: "mac_pro")
        #expect(extensionRecordIDs.count == 77)

        // 2. Fallback path (without tabIDs, using windowIndex and tabIndex)
        var fallbackTabs: [BrowserSearchResult] = []
        for i in 1...18 {
            fallbackTabs.append(BrowserSearchResult(
                title: "Window 1 Tab \(i)",
                url: "https://example.com/w1/t\(i)",
                browserName: "Google Chrome",
                type: .tab,
                timestamp: Date(),
                windowIndex: 1,
                tabIndex: i,
                tabID: nil
            ))
        }
        for i in 1...59 {
            fallbackTabs.append(BrowserSearchResult(
                title: "Window 2 Tab \(i)",
                url: "https://example.com/w2/t\(i)",
                browserName: "Google Chrome",
                type: .tab,
                timestamp: Date(),
                windowIndex: 2,
                tabIndex: i,
                tabID: nil
            ))
        }
        #expect(fallbackTabs.count == 77)
        let fallbackRecordIDs = SyncService.tabRecordIDs(from: fallbackTabs, deviceID: "mac_pro")
        #expect(fallbackRecordIDs.count == 77)
    }

    @Test("SyncService tabContentFingerprint detects positional moves on the fallback path but not the extension path")
    func tabContentFingerprintPositionalMoves() {
        // Fallback path (no tab ID): a browser reorder reassigns tabIndex,
        // which changes the record name — so the fingerprint must change.
        let original = BrowserSearchResult(
            title: "A",
            url: "https://a.com",
            browserName: "Edge",
            type: .tab,
            timestamp: Date(),
            windowIndex: 1,
            tabIndex: 1
        )
        let moved = BrowserSearchResult(
            title: "A",
            url: "https://a.com",
            browserName: "Edge",
            type: .tab,
            timestamp: Date(),
            windowIndex: 1,
            tabIndex: 2
        )
        #expect(SyncService.tabContentFingerprint([original]) != SyncService.tabContentFingerprint([moved]))

        // Extension path (stable tab ID): the same positional move is a no-op
        // because the record name is tab-ID-stable.
        let originalWithID = BrowserSearchResult(
            title: "A",
            url: "https://a.com",
            browserName: "Edge",
            type: .tab,
            timestamp: Date(),
            windowIndex: 1,
            tabIndex: 1,
            tabID: 7
        )
        let movedWithID = BrowserSearchResult(
            title: "A",
            url: "https://a.com",
            browserName: "Edge",
            type: .tab,
            timestamp: Date(),
            windowIndex: 1,
            tabIndex: 2,
            tabID: 7
        )
        #expect(SyncService.tabContentFingerprint([originalWithID]) == SyncService.tabContentFingerprint([movedWithID]))
    }

    @Test("SyncService restores published tab IDs and deletes stale records after relaunch")
    func restoredPublishedTabIDsReconcileFreshState() throws {
        let suiteName = "SyncServiceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let tabA = CKRecord.ID(recordName: "tab_A", zoneID: SyncConstants.stateZoneID)
        let tabB = CKRecord.ID(recordName: "tab_B", zoneID: SyncConstants.stateZoneID)

        SyncService.persistPublishedTabRecordIDs(
            [tabA, tabB],
            deviceID: "mac_test",
            defaults: defaults
        )

        let restoredRecordIDs = SyncService.loadPublishedTabRecordIDs(
            deviceID: "mac_test",
            defaults: defaults
        )
        let recordIDsToDelete = SyncService.tabRecordIDsToDelete(
            previouslyPublished: restoredRecordIDs,
            currentlyPublished: [tabA]
        )

        #expect(restoredRecordIDs == [tabA, tabB])
        #expect(recordIDsToDelete == [tabB])
    }

    @Test("SyncService retains delete candidates in durable ledger until CloudKit acknowledgment")
    func publishedTabLedgerWaitsForDeleteAcknowledgment() throws {
        let suiteName = "SyncServiceLedgerTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let tabA = CKRecord.ID(recordName: "tab_A", zoneID: SyncConstants.stateZoneID)
        let tabB = CKRecord.ID(recordName: "tab_B", zoneID: SyncConstants.stateZoneID)

        SyncService.persistPublishedTabRecordIDs(
            [tabA, tabB],
            deviceID: "mac_test",
            defaults: defaults
        )
        let restoredRecordIDs = SyncService.loadPublishedTabRecordIDs(
            deviceID: "mac_test",
            defaults: defaults
        )

        let ledgerWhileDeleteIsPending = SyncService.tabRecordLedgerAfterPublishing(
            remotelyKnown: restoredRecordIDs,
            currentlyPublished: [tabA]
        )
        SyncService.persistPublishedTabRecordIDs(
            ledgerWhileDeleteIsPending,
            deviceID: "mac_test",
            defaults: defaults
        )

        #expect(
            SyncService.loadPublishedTabRecordIDs(deviceID: "mac_test", defaults: defaults)
                == [tabA, tabB]
        )

        let ledgerAfterAcknowledgment = SyncService.tabRecordLedgerAfterAcknowledgingDeletions(
            remotelyKnown: ledgerWhileDeleteIsPending,
            deletedRecordIDs: [tabB]
        )
        SyncService.persistPublishedTabRecordIDs(
            ledgerAfterAcknowledgment,
            deviceID: "mac_test",
            defaults: defaults
        )

        #expect(
            SyncService.loadPublishedTabRecordIDs(deviceID: "mac_test", defaults: defaults)
                == [tabA]
        )
    }

    @Test("SyncService ignores completed close commands after pending processing")
    func completedCloseCommandsAreIdempotent() {
        var command = SyncCommand(
            id: "cmd_close_once",
            kind: .closeTab,
            targetDeviceID: "mac_test",
            sourceDeviceName: "iPhone",
            issuedAt: Date(),
            expiresAt: Date().addingTimeInterval(3600),
            payloadJSON: "{}"
        )

        #expect(SyncService.shouldProcessIncomingCommand(command))

        command.status = .done
        command.completedAt = Date()

        #expect(!SyncService.shouldProcessIncomingCommand(command))
    }

    @Test("SyncService publishes a device heartbeat every 3 minutes")
    func deviceHeartbeatInterval() {
        // The phone calls a Mac asleep after 600s without a heartbeat, so the
        // interval has to stay comfortably under that.
        let lastPublishedAt = Date(timeIntervalSince1970: 1_000)
        #expect(!SyncService.shouldPublishDeviceHeartbeat(lastPublishedAt: lastPublishedAt, now: Date(timeIntervalSince1970: 1_179)))
        #expect(SyncService.shouldPublishDeviceHeartbeat(lastPublishedAt: lastPublishedAt, now: Date(timeIntervalSince1970: 1_180)))
        #expect(SyncService.shouldPublishDeviceHeartbeat(lastPublishedAt: nil, now: Date(timeIntervalSince1970: 0)))
    }

    @Test("Any queued record retry requests one follow-up send")
    func queuedRecordRetrySendDecision() {
        #expect(!SyncService.shouldRequestRecordRetrySend(queuedSaveRetry: false, queuedDeleteRetry: false))
        #expect(SyncService.shouldRequestRecordRetrySend(queuedSaveRetry: true, queuedDeleteRetry: false))
        #expect(SyncService.shouldRequestRecordRetrySend(queuedSaveRetry: false, queuedDeleteRetry: true))
        #expect(SyncService.shouldRequestRecordRetrySend(queuedSaveRetry: true, queuedDeleteRetry: true))
    }

    @Test("Interrupted command recovery is idempotent for every supported kind")
    func interruptedCommandRecoveryPolicy() {
        let completedAt = Date(timeIntervalSince1970: 1_700_000_000)
        func command(_ kind: SyncCommandKind) -> SyncCommand {
            SyncCommand(kind: kind, targetDeviceID: "mac", sourceDeviceName: "iPhone", payloadJSON: "{}")
        }

        #expect(SyncService.terminalResponseForInterruptedCommand(command(.closeTab), completedAt: completedAt) == nil)
        for kind in [SyncCommandKind.openOnMac, .deleteBookmark, .deleteHistoryItem] {
            let response = SyncService.terminalResponseForInterruptedCommand(command(kind), completedAt: completedAt)
            #expect(response?.status == .refused)
            #expect(response?.completedAt == completedAt)
        }
    }

    @Test("SyncService retries a command conflict with the server-backed record")
    func commandConflictAdoptsServerRecord() throws {
        let pending = SyncCommand(
            id: "cmd_close_conflict",
            kind: .closeTab,
            targetDeviceID: "mac_test",
            sourceDeviceName: "iPhone",
            payloadJSON: "{}"
        )
        let serverRecord = pending.toRecord(zoneID: SyncConstants.commandsZoneID)
        serverRecord["serverOwnedField"] = "preserve-me" as NSString
        var completed = pending
        completed.status = .done
        completed.completedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let intendedRecord = completed.toRecord(zoneID: SyncConstants.commandsZoneID)
        let conflict = CKError(
            .serverRecordChanged,
            userInfo: [CKRecordChangedErrorServerRecordKey: serverRecord]
        )

        let retryRecord = try #require(
            SyncService.recordForRetry(intendedRecord: intendedRecord, error: conflict)
        )

        #expect(retryRecord === serverRecord)
        #expect(retryRecord["serverOwnedField"] as? String == "preserve-me")
        #expect(retryRecord["status"] as? String == SyncCommandStatus.done.rawValue)
    }

    @Test("SyncService re-inserts a state record whose cached server copy was deleted")
    func unknownItemStateRecordRetriesAsFreshInsert() throws {
        let tab = SyncedTab(
            id: "tab_reused_position",
            deviceID: "mac_test",
            browserName: "Microsoft Edge",
            title: "Current title",
            url: "https://example.com/current"
        )
        let intendedRecord = tab.toRecord(zoneID: SyncConstants.stateZoneID)
        let missing = CKError(.unknownItem)

        let retryRecord = try #require(
            SyncService.recordForRetry(intendedRecord: intendedRecord, error: missing)
        )

        #expect(retryRecord !== intendedRecord)
        #expect(retryRecord.recordID == intendedRecord.recordID)
        #expect(retryRecord.recordChangeTag == nil)
        #expect(SyncedTab(from: retryRecord)?.title == "Current title")
        #expect(SyncedTab(from: retryRecord)?.url == "https://example.com/current")
    }

    @Test("SyncService does not resurrect a command record the phone deleted")
    func unknownItemCommandRecordIsNotRetried() {
        let command = SyncCommand(
            id: "cmd_cleared_by_phone",
            kind: .openOnMac,
            targetDeviceID: "mac_1",
            sourceDeviceName: "iPhone",
            issuedAt: Date(),
            expiresAt: Date().addingTimeInterval(3600),
            payloadJSON: "{}"
        )
        let intendedRecord = command.toRecord(zoneID: SyncConstants.commandsZoneID)
        #expect(SyncService.recordForRetry(intendedRecord: intendedRecord, error: CKError(.unknownItem)) == nil)
    }

    @Test("SyncService retries a synced-tab conflict with the server-backed record")
    func syncedTabConflictAdoptsServerRecord() throws {
        let serverTab = SyncedTab(
            id: "tab_conflict",
            deviceID: "mac_test",
            browserName: "Safari",
            title: "Old title",
            url: "https://example.com/old"
        )
        let serverRecord = serverTab.toRecord(zoneID: SyncConstants.stateZoneID)
        serverRecord["serverOwnedField"] = "preserve-me" as NSString
        let currentTab = SyncedTab(
            id: "tab_conflict",
            deviceID: "mac_test",
            browserName: "Safari",
            title: "Current title",
            url: "https://example.com/current",
            isPinned: true
        )
        let intendedRecord = currentTab.toRecord(zoneID: SyncConstants.stateZoneID)
        let conflict = CKError(
            .serverRecordChanged,
            userInfo: [CKRecordChangedErrorServerRecordKey: serverRecord]
        )

        let retryRecord = try #require(
            SyncService.recordForRetry(intendedRecord: intendedRecord, error: conflict)
        )

        #expect(retryRecord === serverRecord)
        #expect(retryRecord["serverOwnedField"] as? String == "preserve-me")
        #expect(retryRecord.encryptedValues["title"] as? String == "Current title")
        #expect((retryRecord["isPinned"] as? NSNumber)?.boolValue == true)
    }

    // Disabled because it crashes the whole test process, not because of what it
    // asserts. `BrowserTabService.shared` resolves `AppState.shared`, whose init
    // calls `SyncService.shared.start()`, which constructs
    // `CKContainer(identifier: "iCloud.app.theindie.FastTab")`. CloudKit traps
    // (SIGTRAP) when the host process is not entitled for that container, and the
    // swift-testing runner is not. Re-enable once `BrowserTabService` can be
    // built for a test without pulling in the app-wide singleton graph.
    @Test(
        "BrowserTabService recordClosedTabFromRemote adds tombstone and updates live tab counts",
        .disabled("Resolving BrowserTabService.shared builds CKContainer, which traps in an unentitled test host")
    )
    @MainActor
    func recordClosedTabFromRemote() {
        let service = BrowserTabService.shared
        let tab = BrowserSearchResult(
            title: "Test Page",
            url: "https://example.com/test-remote-close",
            browserName: "Safari",
            type: .tab,
            timestamp: Date()
        )
        service.setTestLiveTabsState(tabs: [tab])

        service.recordClosedTabFromRemote(browserName: "Safari", url: "https://example.com/test-remote-close")

        #expect(service.results.isEmpty)
        #expect(service.cachedLiveTabs.isEmpty)
        #expect(service.openTabCount == 0)
    }
}
