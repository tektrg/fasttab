import Testing
import Foundation
@testable import FastTab
@testable import FastTabSync

/// Push routing and the poll cadence it relaxes. Both are pure decisions on
/// purpose — a test host can't construct a `CKContainer` without hard-trapping.
struct CloudKitPushRoutingTests {
    @Test("A push for our own container triggers a fetch")
    func ownContainerFetches() {
        #expect(
            CloudKitPushRouting.decision(containerIdentifier: SyncConstants.containerIdentifier)
                == .fetchChanges
        )
    }

    @Test("A push for some other container is ignored")
    func foreignContainerIgnored() {
        #expect(
            CloudKitPushRouting.decision(containerIdentifier: "iCloud.com.example.Other")
                == .ignore
        )
    }

    @Test("An unattributable CloudKit push still fetches — a wasted round trip beats lost realtime")
    func missingContainerIdentifierFetches() {
        #expect(CloudKitPushRouting.decision(containerIdentifier: nil) == .fetchChanges)
    }

    @Test("A non-CloudKit notification payload is ignored")
    func nonCloudKitPayloadIgnored() {
        #expect(CloudKitPushRouting.decision(forRemoteNotification: ["aps": ["alert": "hi"]]) == .ignore)
    }

    @Test("The poll stays tight until push proves itself, then relaxes")
    func pollRelaxesOnlyAfterPush() {
        let beforePush = SyncService.pollInterval(hasReceivedPush: false)
        let afterPush = SyncService.pollInterval(hasReceivedPush: true)
        #expect(beforePush < afterPush)
        #expect(beforePush == 15.0)
        #expect(afterPush == 60.0)
    }
}
