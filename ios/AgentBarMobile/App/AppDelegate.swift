import AgentBarCore
import UIKit
import UserNotifications

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    let model = SettingsModel()

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories(NotificationCategories.all)
        return true
    }

    // MARK: Remote registration

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        model.didReceiveDeviceToken(DeviceTokenHex.encode(deviceToken))
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        model.status = "Push registration failed: \(error.localizedDescription)"
    }

    /// Silent push: {"withdrawn": requestId} -> remove that prompt (collapse id = requestId).
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        guard let requestId = AgentBarPush.withdrawnRequestId(from: userInfo) else { return completionHandler(.noData) }
        let center = UNUserNotificationCenter.current()
        center.getDeliveredNotifications { delivered in
            let ids = delivered.filter {
                $0.request.identifier == requestId
                    || AgentBarPush.permissionPrompt(from: $0.request.content.userInfo)?.requestId == requestId
            }.map(\.request.identifier)
            center.removeDeliveredNotifications(withIdentifiers: ids)
            completionHandler(ids.isEmpty ? .noData : .newData)
        }
    }

    // MARK: Notification actions (run in background; no .foreground option)

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let content = response.notification.request.content
        switch content.categoryIdentifier {
        case AgentBarPush.Category.permission:
            answerPermission(response, completion: completionHandler)
        case AgentBarPush.Category.message:
            // Stub: no server sender/route for agent messages yet (phase 2 contract only).
            completionHandler()
        default:
            completionHandler()
        }
    }

    private func answerPermission(_ response: UNNotificationResponse, completion: @escaping () -> Void) {
        let replyText = (response as? UNTextInputNotificationResponse)?.userText
        guard let prompt = AgentBarPush.permissionPrompt(from: response.notification.request.content.userInfo),
              let answer = PermissionAnswer(actionIdentifier: response.actionIdentifier, replyText: replyText)
        else { return completion() }  // plain tap: just opens the app
        guard let api = AgentBarClient.currentAPI() else {
            postFailure(agent: prompt.agent, reason: "AgentBar isn't set up on this phone.")
            return completion()
        }
        AgentBarClient.send(api.answerRequest(requestId: prompt.requestId, answer: answer)) { [weak self] result in
            if case .failure(let failure) = result {
                self?.postFailure(agent: prompt.agent, reason: Self.describe(failure))
            }
            completion()
        }
    }

    private func postFailure(agent: String, reason: String) {
        let content = UNMutableNotificationContent()
        content.title = "Couldn't reach Mac"
        content.body = agent.isEmpty ? reason : "\(agent): \(reason) Answer it on the Mac."
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    private static func describe(_ failure: AgentBarClient.Failure) -> String {
        switch failure {
        case .notConfigured: return "AgentBar isn't set up on this phone."
        case .http(401), .http(403): return "The Mac refused the token."
        case .http(404), .http(409), .http(410): return "That prompt was already answered or expired."
        case .http(let code): return "The Mac answered with error \(code)."
        case .transport(let error): return error.localizedDescription
        }
    }
}

enum NotificationCategories {
    static var all: Set<UNNotificationCategory> {
        typealias A = AgentBarPush.Action
        let reply = UNTextInputNotificationAction(identifier: A.reply, title: "Reply", options: [],
                                                  textInputButtonTitle: "Send", textInputPlaceholder: "Tell the agent…")
        let permission = UNNotificationCategory(
            identifier: AgentBarPush.Category.permission,
            actions: [UNNotificationAction(identifier: A.allow, title: "Allow", options: [.authenticationRequired]),
                      UNNotificationAction(identifier: A.deny, title: "Deny", options: [.destructive]),
                      reply],
            intentIdentifiers: [], options: [])
        let message = UNNotificationCategory(
            identifier: AgentBarPush.Category.message,
            actions: [reply,
                      UNNotificationAction(identifier: A.continue, title: "Continue", options: []),
                      UNNotificationAction(identifier: A.stop, title: "Stop", options: [.destructive])],
            intentIdentifiers: [], options: [])
        return [permission, message]
    }
}
