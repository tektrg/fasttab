import Foundation
import CloudKit

public enum SyncConstants {
    public static let containerIdentifier = "iCloud.app.theindie.FastTab"
    public static let appGroupIdentifier = "group.app.theindie.FastTab"

    // CloudKit Custom Zones
    public static let stateZoneName = "StateZone"
    public static let commandsZoneName = "CommandsZone"
    /// Reader highlights and their comment events (ReaderSyncBridge), written by both apps.
    public static let readerZoneName = "ReaderZone"

    public static let stateZoneID = CKRecordZone.ID(zoneName: stateZoneName, ownerName: CKCurrentUserDefaultName)
    public static let commandsZoneID = CKRecordZone.ID(zoneName: commandsZoneName, ownerName: CKCurrentUserDefaultName)
    public static let readerZoneID = CKRecordZone.ID(zoneName: readerZoneName, ownerName: CKCurrentUserDefaultName)
}
