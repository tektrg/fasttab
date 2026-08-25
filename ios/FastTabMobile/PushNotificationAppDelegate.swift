import UIKit
import OSLog
import FastTabSync

/// Exists for one reason: SwiftUI has no hook for remote notifications, so a
/// `UIApplicationDelegate` is the only way to receive CloudKit's silent change
/// pushes — the difference between sync that feels instant and sync that waits
/// for the next poll.
final class PushNotificationAppDelegate: NSObject, UIApplicationDelegate {
    private static let logger = Logger(
        subsystem: "app.theindie.FastTabMobile",
        category: "PushNotifications"
    )

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // No `UNUserNotificationCenter` authorization request, deliberately:
        // these are silent data pushes that never surface a banner, and asking
        // would put a permission alert in front of the user for a feature they
        // will never see. A user who declines notifications still gets sync.
        application.registerForRemoteNotifications()
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Self.logger.info("Registered for CloudKit pushes (token \(deviceToken.count, privacy: .public) bytes)")
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        // Almost always provisioning: the App ID or the profile does not carry
        // the Push Notifications capability. Sync still works on its poll, just
        // not instantly — loud in the log, silent in the UI.
        Self.logger.error("CloudKit push registration failed: \(error.localizedDescription, privacy: .public)")
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        guard CloudKitPushRouting.decision(forRemoteNotification: userInfo) == .fetchChanges else {
            completionHandler(.noData)
            return
        }

        Task { @MainActor in
            // The handler must be called *after* the pull finishes: iOS ends the
            // app's background window the moment it is invoked, which would cut
            // the fetch off mid-flight.
            let didFetch = await SyncConsumer.shared.handleRemoteNotification()
            completionHandler(didFetch ? .newData : .failed)
        }
    }
}
