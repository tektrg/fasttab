import AgentBarCore
import SwiftUI
import UserNotifications

@MainActor
final class SettingsModel: ObservableObject {
    @Published var baseURL = AppSettings.baseURL ?? ""
    @Published var tokenInput = ""
    @Published var hasToken = KeychainStore.readToken() != nil
    @Published var status = AppSettings.registeredDeviceToken == nil ? "Not registered." : "Registered with Mac."

    func saveSettings() -> AgentBarAPI? {
        AppSettings.baseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = tokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if !token.isEmpty { KeychainStore.saveToken(token); tokenInput = ""; hasToken = true }
        guard let api = AgentBarClient.currentAPI() else {
            status = "Enter a valid server URL and token."
            return nil
        }
        return api
    }

    func enableNotifications() {
        guard saveSettings() != nil else { return }
        status = "Asking for permission…"
        // .timeSensitive is an interruption level, granted via the entitlement, not an auth option.
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            Task { @MainActor in
                guard granted else {
                    self.status = "Notifications denied\(error.map { ": \($0.localizedDescription)" } ?? ""). Enable in Settings."
                    return
                }
                self.status = "Registering…"
                UIApplication.shared.registerForRemoteNotifications()
            }
        }
    }

    nonisolated func didReceiveDeviceToken(_ hex: String) {
        Task { @MainActor in
            guard let api = AgentBarClient.currentAPI() else { self.status = "Not configured."; return }
            AgentBarClient.send(api.registerDeviceRequest(deviceToken: hex, label: UIDevice.current.name)) { result in
                switch result {
                case .success:
                    AppSettings.registeredDeviceToken = hex
                    self.status = "Registered with Mac."
                case .failure(let f):
                    self.status = "Couldn't register with Mac (\(f))."
                }
            }
        }
    }

    func signOut() {
        let finish = {
            KeychainStore.deleteToken()
            AppSettings.registeredDeviceToken = nil
            self.hasToken = false
            UIApplication.shared.unregisterForRemoteNotifications()
        }
        guard let api = AgentBarClient.currentAPI(), let hex = AppSettings.registeredDeviceToken else {
            finish(); status = "Signed out."; return
        }
        AgentBarClient.send(api.unregisterDeviceRequest(deviceToken: hex)) { result in
            finish()
            if case .success = result { self.status = "Signed out." }
            else { self.status = "Signed out here; the Mac may still list this phone." }
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        NavigationStack {
            Form {
                Section("Mac") {
                    TextField("my-mac.tailnet.ts.net", text: $model.baseURL)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField(model.hasToken ? "Token saved (paste to replace)" : "Paste remote token", text: $model.tokenInput)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Section {
                    Button("Enable Notifications") { model.enableNotifications() }
                    Text(model.status).font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    Button("Sign out", role: .destructive) { model.signOut() }.disabled(!model.hasToken)
                }
            }
            .navigationTitle("AgentBar")
        }
    }
}
