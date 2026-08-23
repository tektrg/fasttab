import Foundation
import OSLog
import FastTabSync

/// Single place that decides where FastTab's on-device files live.
///
/// The app-group container is shared with the share extension. When it is
/// unavailable (for example an entitlement-less debug build) we degrade to the
/// app's Documents directory rather than dropping writes on the floor. Both the
/// local cache, the sync-engine state file and the command outbox resolve their
/// paths through here so they can never disagree about the location.
public enum AppGroupContainer {
    private static let logger = Logger(subsystem: "app.theindie.FastTab", category: "AppGroupContainer")

    public static var directoryURL: URL {
        if let groupURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: SyncConstants.appGroupIdentifier
        ) {
            return groupURL
        }
        // Worth shouting about: files written here are invisible to the share
        // extension, and become invisible again once the entitlement resolves.
        logger.error("App group container unavailable; falling back to the app's own Documents directory")
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
    }

    public static func fileURL(forFileNamed fileName: String) -> URL {
        directoryURL.appendingPathComponent(fileName)
    }
}
