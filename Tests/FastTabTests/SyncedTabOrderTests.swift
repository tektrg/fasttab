import Foundation
import Testing
import CloudKit
@testable import FastTabSync

struct SyncedTabOrderTests {
    @Test func contentHashChangesOnOrderOrGhostChange() {
        let slot1 = SyncedOrderedSlot(
            slotID: UUID(),
            matchKey: "https://example.com/1",
            title: "One",
            url: "https://example.com/1",
            browserName: "Google Chrome",
            profileName: "Default",
            state: "live",
            ghostedAt: nil
        )
        let slot2 = SyncedOrderedSlot(
            slotID: UUID(),
            matchKey: "https://example.com/2",
            title: "Two",
            url: "https://example.com/2",
            browserName: "Google Chrome",
            profileName: "Default",
            state: "live",
            ghostedAt: nil
        )

        let order1 = SyncedTabOrder(deviceID: "dev1", slots: [slot1, slot2])
        let order2 = SyncedTabOrder(deviceID: "dev1", slots: [slot2, slot1])
        #expect(order1.contentHash != order2.contentHash)

        // Changing ghost status changes hash
        let slot1Ghost = SyncedOrderedSlot(
            slotID: slot1.slotID,
            matchKey: slot1.matchKey,
            title: slot1.title,
            url: slot1.url,
            browserName: slot1.browserName,
            profileName: slot1.profileName,
            state: "ghost",
            ghostedAt: Date()
        )
        let order3 = SyncedTabOrder(deviceID: "dev1", slots: [slot1Ghost, slot2])
        #expect(order1.contentHash != order3.contentHash)
    }

    @Test func roundtripCKRecordConversion() {
        let zoneID = CKRecordZone.ID(zoneName: "state_zone", ownerName: CKCurrentUserDefaultName)
        let slot = SyncedOrderedSlot(
            slotID: UUID(),
            matchKey: "https://example.com",
            title: "Example",
            url: "https://example.com",
            browserName: "Safari",
            profileName: nil,
            state: "live",
            ghostedAt: nil
        )
        let order = SyncedTabOrder(deviceID: "dev_mac", slots: [slot])
        let record = order.toRecord(zoneID: zoneID)

        let decoded = SyncedTabOrder(from: record)
        #expect(decoded != nil)
        #expect(decoded?.deviceID == "dev_mac")
        #expect(decoded?.slots.count == 1)
        #expect(decoded?.slots[0].title == "Example")
    }
}
