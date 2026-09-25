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

    @Test("PendingApprovalStore add, deduplicate, approve, and dismiss lifecycle")
    @MainActor
    func pendingApprovalStoreLifecycle() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = tempDir.appendingPathComponent("test_pending_approvals.json")

        let store = PendingApprovalStore(fileURL: fileURL)

        let bookmarkPayload = DeleteBookmarkPayload(browserName: "Google Chrome", profileName: "Default", bookmarkID: "bm_123", url: "https://example.com/bm")
        let bmData = try JSONEncoder().encode(bookmarkPayload)
        let bmJSON = String(data: bmData, encoding: .utf8)!

        let cmd = SyncCommand(
            id: "cmd_del_bm",
            kind: .deleteBookmark,
            targetDeviceID: "mac_1",
            sourceDeviceName: "Trung's iPhone",
            issuedAt: Date(),
            expiresAt: Date().addingTimeInterval(3600),
            payloadJSON: bmJSON
        )

        let item = store.add(command: cmd)
        #expect(item != nil)
        #expect(store.items.count == 1)
        #expect(store.items.first?.commandID == "cmd_del_bm")
        #expect(store.items.first?.kind == .deleteBookmark)
        #expect(store.items.first?.url == "https://example.com/bm")

        // Adding same command again returns existing without duplicate
        let dup = store.add(command: cmd)
        #expect(dup?.id == item?.id)
        #expect(store.items.count == 1)

        // Reload from disk to verify persistence
        let reloadedStore = PendingApprovalStore(fileURL: fileURL)
        #expect(reloadedStore.items.count == 1)

        // Approve item
        reloadedStore.approve(item: item!)
        #expect(reloadedStore.items.isEmpty)

        // Dismiss item test
        let histPayload = DeleteHistoryItemPayload(browserName: "Google Chrome", url: "https://example.com/history")
        let histData = try JSONEncoder().encode(histPayload)
        let histJSON = String(data: histData, encoding: .utf8)!

        let histCmd = SyncCommand(
            id: "cmd_del_hist",
            kind: .deleteHistoryItem,
            targetDeviceID: "mac_1",
            sourceDeviceName: "Trung's iPhone",
            issuedAt: Date(),
            expiresAt: Date().addingTimeInterval(3600),
            payloadJSON: histJSON
        )

        let histItem = store.add(command: histCmd)
        #expect(histItem != nil)
        #expect(store.items.count == 1)

        store.dismiss(item: histItem!)
        #expect(store.items.isEmpty)

        // Clean up
        try? FileManager.default.removeItem(at: tempDir)
    }

    @Test("PendingApprovalStore ignores expired delete commands")
    @MainActor
    func pendingApprovalStoreExpired() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = tempDir.appendingPathComponent("test_pending_expired.json")

        let store = PendingApprovalStore(fileURL: fileURL)

        let bookmarkPayload = DeleteBookmarkPayload(browserName: "Google Chrome", profileName: "Default", bookmarkID: "bm_old", url: "https://old.com")
        let bmData = try JSONEncoder().encode(bookmarkPayload)
        let bmJSON = String(data: bmData, encoding: .utf8)!

        let expiredCmd = SyncCommand(
            id: "cmd_expired_del",
            kind: .deleteBookmark,
            targetDeviceID: "mac_1",
            sourceDeviceName: "iPhone",
            issuedAt: Date().addingTimeInterval(-7200),
            expiresAt: Date().addingTimeInterval(-3600),
            payloadJSON: bmJSON
        )

        let item = store.add(command: expiredCmd)
        #expect(item == nil)
        #expect(store.items.isEmpty)

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

    @Test("BrowserTabService recordClosedTabFromRemote adds tombstone and updates live tab counts")
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
