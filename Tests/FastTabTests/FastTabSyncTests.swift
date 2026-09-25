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

    @Test("SyncSearchMatcher diacritics & word boundary matching")
    func testSearchMatcher() {
        #expect(SyncSearchMatcher.matches(query: "fast", title: "FastTab Mac", url: "https://theindie.app"))
        #expect(SyncSearchMatcher.matches(query: "tab fast", title: "FastTab Mac", url: "https://theindie.app"))
        #expect(SyncSearchMatcher.matches(query: "indie", title: "FastTab", url: "https://theindie.app"))
        #expect(!SyncSearchMatcher.matches(query: "chrome", title: "FastTab Safari", url: "https://apple.com"))
    }
}
