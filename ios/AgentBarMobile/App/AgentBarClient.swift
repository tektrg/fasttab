import AgentBarCore
import UIKit

/// Sends requests to the Mac, keeping the app alive in the background until done.
enum AgentBarClient {
    enum Failure: Error { case notConfigured, http(Int), transport(Error) }

    static func currentAPI() -> AgentBarAPI? {
        guard let token = KeychainStore.readToken(), !token.isEmpty,
              let base = AppSettings.baseURL, !base.isEmpty else { return nil }
        return try? AgentBarAPI(baseURLString: base, token: token)
    }

    /// Runs `request` inside a background task; completion on the main queue.
    static func send(_ request: URLRequest, completion: @escaping (Result<Void, Failure>) -> Void) {
        var taskId = UIBackgroundTaskIdentifier.invalid
        let finish: (Result<Void, Failure>) -> Void = { result in
            DispatchQueue.main.async {
                completion(result)
                if taskId != .invalid { UIApplication.shared.endBackgroundTask(taskId); taskId = .invalid }
            }
        }
        taskId = UIApplication.shared.beginBackgroundTask(withName: "agentbar-send") {
            if taskId != .invalid { UIApplication.shared.endBackgroundTask(taskId); taskId = .invalid }
        }
        URLSession.shared.dataTask(with: request) { _, response, error in
            if let error { return finish(.failure(.transport(error))) }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            finish((200..<300).contains(status) ? .success(()) : .failure(.http(status)))
        }.resume()
    }
}

/// Non-secret settings (UserDefaults).
enum AppSettings {
    private static let defaults = UserDefaults.standard
    static var baseURL: String? {
        get { defaults.string(forKey: "baseURL") }
        set { defaults.set(newValue, forKey: "baseURL") }
    }
    /// Hex APNs token last registered with the Mac (needed to unregister).
    static var registeredDeviceToken: String? {
        get { defaults.string(forKey: "registeredDeviceToken") }
        set { defaults.set(newValue, forKey: "registeredDeviceToken") }
    }
}
