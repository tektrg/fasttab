import Testing
import CloudKit
import Foundation
@testable import FastTabSync

@Suite("FastTabSync Wire Models & CloudKit Record Conversion")
struct FastTabSyncTests {

    @Test("SyncedDevice CloudKit round-trip")
    func testSyncedDeviceRecordConversion() {
        let zoneID = CKRecordZone.ID(zoneName: "StateZone", ownerName: CKCurrentUserDefaultName)
        let device = SyncedDevice(
            id: "macbook-pro-1",
            name: "MacBook Pro",
            modelName: "Mac15,6",
            lastSeenAt: Date(timeIntervalSince1970: 1700000000),
            appVersion: "1.3.0"
        )

        let record = device.toRecord(zoneID: zoneID)
        let decoded = SyncedDevice(from: record)

        #expect(decoded != nil)
        #expect(decoded?.id == "macbook-pro-1")
        #expect(decoded?.name == "MacBook Pro")
        #expect(decoded?.modelName == "Mac15,6")
        #expect(decoded?.appVersion == "1.3.0")
    }

    @Test("Stable-ID state models update fetched CloudKit records in place")
    func stableIDStateModelsPreserveFetchedRecords() throws {
        let zoneID = CKRecordZone.ID(zoneName: "StateZone", ownerName: CKCurrentUserDefaultName)
        let oldDevice = SyncedDevice(id: "mac-1", name: "Mac", modelName: "Mac", lastSeenAt: .distantPast, appVersion: "1")
        let deviceRecord = oldDevice.toRecord(zoneID: zoneID)
        let currentDevice = SyncedDevice(id: "mac-1", name: "Mac", modelName: "Mac", lastSeenAt: Date(), appVersion: "2")
        #expect(currentDevice.applying(to: deviceRecord) === deviceRecord)
        #expect(deviceRecord["appVersion"] as? String == "2")

        let bookmark = SyncedBookmarkBlob(deviceID: "mac-1", browserName: "Safari", profileName: "Default", bookmarks: [])
        let bookmarkRecord = try #require(bookmark.toRecord(zoneID: zoneID))
        #expect(bookmark.applying(to: bookmarkRecord) === bookmarkRecord)

        let history = SyncedHistorySlice(deviceID: "mac-1", browserName: "Safari", entries: [])
        let historyRecord = try #require(history.toRecord(zoneID: zoneID))
        #expect(history.applying(to: historyRecord) === historyRecord)
    }

    @Test("SyncedTab CloudKit encrypted round-trip")
    func testSyncedTabRecordConversion() {
        let zoneID = CKRecordZone.ID(zoneName: "StateZone", ownerName: CKCurrentUserDefaultName)
        let tab = SyncedTab(
            id: "tab-123",
            deviceID: "macbook-pro-1",
            browserName: "Google Chrome",
            title: "GitHub - FastTab",
            url: "https://github.com/trungluong/fasttab",
            timestamp: Date(timeIntervalSince1970: 1700000000),
            windowIndex: 1,
            tabIndex: 2,
            windowName: "Work Window",
            tabID: 456,
            isAudible: true,
            isMuted: false,
            isPinned: true,
            isDiscarded: false,
            tabGroupTitle: "Projects",
            profileName: "Default"
        )

        let record = tab.toRecord(zoneID: zoneID)

        // Verify private fields are stored in encryptedValues
        #expect(record.encryptedValues["title"] as? String == "GitHub - FastTab")
        #expect(record.encryptedValues["url"] as? String == "https://github.com/trungluong/fasttab")

        let decoded = SyncedTab(from: record)
        #expect(decoded != nil)
        #expect(decoded?.id == "tab-123")
        #expect(decoded?.title == "GitHub - FastTab")
        #expect(decoded?.url == "https://github.com/trungluong/fasttab")
        #expect(decoded?.isAudible == true)
        #expect(decoded?.isPinned == true)
        #expect(decoded?.tabGroupTitle == "Projects")
    }

    @Test("Updating a fetched synced tab preserves its CloudKit record metadata")
    func updatingFetchedSyncedTabPreservesRecord() {
        let zoneID = CKRecordZone.ID(zoneName: "StateZone", ownerName: CKCurrentUserDefaultName)
        let fetchedTab = SyncedTab(
            id: "tab-123",
            deviceID: "macbook-pro-1",
            browserName: "Safari",
            title: "Old title",
            url: "https://example.com/old"
        )
        let fetchedRecord = fetchedTab.toRecord(zoneID: zoneID)
        fetchedRecord["serverOwnedField"] = "preserve-me" as NSString
        let currentTab = SyncedTab(
            id: "tab-123",
            deviceID: "macbook-pro-1",
            browserName: "Safari",
            title: "Current title",
            url: "https://example.com/current",
            isPinned: true
        )

        let updatedRecord = currentTab.applying(to: fetchedRecord)

        #expect(updatedRecord === fetchedRecord)
        #expect(updatedRecord["serverOwnedField"] as? String == "preserve-me")
        #expect(updatedRecord.encryptedValues["title"] as? String == "Current title")
        #expect(updatedRecord.encryptedValues["url"] as? String == "https://example.com/current")
        #expect((updatedRecord["isPinned"] as? NSNumber)?.boolValue == true)
    }

    @Test("SyncedBookmarkBlob encoding & SHA256 hashing")
    func testBookmarkBlobHashing() {
        let zoneID = CKRecordZone.ID(zoneName: "StateZone", ownerName: CKCurrentUserDefaultName)
        let items = [
            SyncedBookmarkItem(id: "b1", title: "Apple", url: "https://apple.com"),
            SyncedBookmarkItem(id: "b2", title: "FastTab", url: "https://fasttab.theindie.app")
        ]

        let blob = SyncedBookmarkBlob(
            deviceID: "mac-1",
            browserName: "Safari",
            profileName: "Personal",
            bookmarks: items
        )

        #expect(!blob.contentHash.isEmpty)

        let record = blob.toRecord(zoneID: zoneID)
        #expect(record != nil)

        if let record {
            let decoded = SyncedBookmarkBlob(from: record)
            #expect(decoded != nil)
            #expect(decoded?.bookmarks.count == 2)
            #expect(decoded?.bookmarks.first?.title == "Apple")
            #expect(decoded?.contentHash == blob.contentHash)
        }
    }

    @Test("SyncCommand serialization & lifecycle")
    func testSyncCommandConversion() {
        let zoneID = CKRecordZone.ID(zoneName: "CommandsZone", ownerName: CKCurrentUserDefaultName)
        let payload = OpenOnMacPayload(url: "https://theindie.app", title: "The Indie App", preferBrowser: "Safari")
        let payloadData = try! JSONEncoder().encode(payload)
        let payloadJSON = String(data: payloadData, encoding: .utf8)!

        let command = SyncCommand(
            kind: .openOnMac,
            targetDeviceID: "mac-1",
            sourceDeviceName: "Trung's iPhone",
            payloadJSON: payloadJSON,
            status: .pending
        )

        let record = command.toRecord(zoneID: zoneID)
        let decoded = SyncCommand(from: record)

        #expect(decoded != nil)
        #expect(decoded?.kind == .openOnMac)
        #expect(decoded?.targetDeviceID == "mac-1")
        #expect(decoded?.sourceDeviceName == "Trung's iPhone")
        #expect(decoded?.status == .pending)
    }

    @Test("AddBookmarkPayload JSON round-trip")
    func testAddBookmarkPayloadRoundTrip() throws {
        let payload = AddBookmarkPayload(
            browserName: "Google Chrome",
            profileName: "Default",
            title: "FastTab — The Indie App",
            url: "https://theindie.app",
            folderPath: ["Work", "Projects"]
        )
        let data = try #require(try? JSONEncoder().encode(payload))
        let decoded = try #require(try? JSONDecoder().decode(AddBookmarkPayload.self, from: data))
        #expect(decoded.browserName == "Google Chrome")
        #expect(decoded.profileName == "Default")
        #expect(decoded.title == "FastTab — The Indie App")
        #expect(decoded.url == "https://theindie.app")
        #expect(decoded.folderPath == ["Work", "Projects"])
    }

    @Test("Empty folder path round-trips as top-level save")
    func testAddBookmarkPayloadEmptyFolderPathRoundTrip() throws {
        let payload = AddBookmarkPayload(
            browserName: "Microsoft Edge",
            profileName: "Default",
            title: "Top Level",
            url: "https://example.com",
            folderPath: []
        )
        let data = try #require(try? JSONEncoder().encode(payload))
        let decoded = try #require(try? JSONDecoder().decode(AddBookmarkPayload.self, from: data))
        #expect(decoded.folderPath.isEmpty)
    }

    @Test("addBookmark SyncCommand serializes through CloudKit record")
    func testAddBookmarkCommandRecordConversion() {
        let zoneID = CKRecordZone.ID(zoneName: "CommandsZone", ownerName: CKCurrentUserDefaultName)
        let payload = AddBookmarkPayload(
            browserName: "Google Chrome",
            profileName: "Default",
            title: "Save Me",
            url: "https://example.com/save-me",
            folderPath: []
        )
        let payloadData = try! JSONEncoder().encode(payload)
        let payloadJSON = String(data: payloadData, encoding: .utf8)!

        let command = SyncCommand(
            kind: .addBookmark,
            targetDeviceID: "mac-1",
            sourceDeviceName: "Trung's iPhone",
            payloadJSON: payloadJSON,
            status: .pending
        )

        let record = command.toRecord(zoneID: zoneID)
        let decoded = SyncCommand(from: record)

        #expect(decoded != nil)
        #expect(decoded?.kind == .addBookmark)
        #expect(decoded?.targetDeviceID == "mac-1")
        #expect(decoded?.sourceDeviceName == "Trung's iPhone")
        #expect(decoded?.status == .pending)
    }

    @Test("createFolder SyncCommand serializes through CloudKit record")
    func testCreateFolderCommandRecordConversion() {
        let zoneID = CKRecordZone.ID(zoneName: "CommandsZone", ownerName: CKCurrentUserDefaultName)
        let payload = CreateFolderPayload(
            browserName: "Google Chrome",
            profileName: "Default",
            folderName: "Projects",
            parentFolderPath: ["Work"]
        )
        let payloadData = try! JSONEncoder().encode(payload)
        let payloadJSON = String(data: payloadData, encoding: .utf8)!

        let command = SyncCommand(
            kind: .createFolder,
            targetDeviceID: "mac-1",
            sourceDeviceName: "Trung's iPhone",
            payloadJSON: payloadJSON,
            status: .pending
        )

        let record = command.toRecord(zoneID: zoneID)
        let decoded = SyncCommand(from: record)

        #expect(decoded != nil)
        #expect(decoded?.kind == .createFolder)
        #expect(decoded?.targetDeviceID == "mac-1")
        #expect(decoded?.sourceDeviceName == "Trung's iPhone")
        #expect(decoded?.status == .pending)

        let decodedPayload = try? JSONDecoder().decode(CreateFolderPayload.self, from: (decoded?.payloadJSON.data(using: .utf8))!)
        #expect(decodedPayload?.folderName == "Projects")
        #expect(decodedPayload?.parentFolderPath == ["Work"])
    }

    @Test("Completing a fetched command preserves its CloudKit record metadata")
    func completingFetchedCommandPreservesRecord() {
        let zoneID = CKRecordZone.ID(zoneName: "CommandsZone", ownerName: CKCurrentUserDefaultName)
        let pending = SyncCommand(
            id: "close-tab-1",
            kind: .closeTab,
            targetDeviceID: "mac-1",
            sourceDeviceName: "Trung's iPhone",
            payloadJSON: "{}"
        )
        let fetchedRecord = pending.toRecord(zoneID: zoneID)
        fetchedRecord["serverOwnedField"] = "preserve-me" as NSString

        var completed = pending
        completed.status = .done
        completed.statusReason = "Tab closed on Mac"
        completed.completedAt = Date(timeIntervalSince1970: 1_700_000_000)

        let updatedRecord = completed.applying(to: fetchedRecord)

        #expect(updatedRecord === fetchedRecord)
        #expect(updatedRecord["serverOwnedField"] as? String == "preserve-me")
        #expect(updatedRecord["status"] as? String == SyncCommandStatus.done.rawValue)
        #expect(updatedRecord["statusReason"] as? String == "Tab closed on Mac")
        #expect(updatedRecord["completedAt"] as? Date == completed.completedAt)
    }

    @Test("SyncSearchMatcher diacritics & word boundary matching")
    func testSearchMatcher() {
        #expect(SyncSearchMatcher.matches(query: "fast", title: "FastTab Mac", url: "https://theindie.app"))
        #expect(SyncSearchMatcher.matches(query: "tab fast", title: "FastTab Mac", url: "https://theindie.app"))
        #expect(SyncSearchMatcher.matches(query: "indie", title: "FastTab", url: "https://theindie.app"))
        #expect(!SyncSearchMatcher.matches(query: "chrome", title: "FastTab Safari", url: "https://apple.com"))
    }
}
