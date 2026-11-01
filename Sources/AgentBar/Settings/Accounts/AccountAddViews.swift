import SwiftUI

/// The last add/remove result in Settings › Accounts.
enum AccountEditNotice: Equatable {
    case info(String)
    case error(String)
}

extension AccountActionOutcome {
    var notice: AccountEditNotice? {
        if case .failed(let message) = self { return .error(message) }
        return nil
    }
}

/// "Add Claude subscription" (asks for a name, then the dashboard opens its login tab) and
/// "Add API account" (sheet). The API key is sent once to the local dashboard, which keeps it in
/// the macOS Keychain; AgentBar never stores it.
struct AccountAddSection: View {
    @ObservedObject var model: AccountsSettingsModel
    @State private var askingSubscriptionName = false
    @State private var subscriptionName = ""
    @State private var showingAPIForm = false

    var body: some View {
        Section {
            HStack {
                Button("Add to pool") { Task { await model.addToPool() } }
                    .help("Sign another Claude account into the shared pool; all sessions keep your ~/.claude setup")
                Button("Add Claude subscription") { subscriptionName = ""; askingSubscriptionName = true }
                Button("Add API account") { showingAPIForm = true }
            }
            switch model.editNotice {
            case .info(let text)?: Text(text).font(.caption).foregroundStyle(.green)
            case .error(let text)?: PersonaNotice(text: text)
            case nil: EmptyView()
            }
        }
        .alert("Name this subscription", isPresented: $askingSubscriptionName) {
            TextField("e.g. Personal Max", text: $subscriptionName)
            Button("Add and sign in") {
                let name = subscriptionName.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return }
                Task { await model.addSubscription(label: name) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A terminal tab opens with the Claude sign-in; finish it in your browser.")
        }
        .sheet(isPresented: $showingAPIForm) {
            APIAccountForm(model: model) { showingAPIForm = false }
        }
    }
}

private struct APIAccountForm: View {
    @ObservedObject var model: AccountsSettingsModel
    let close: () -> Void
    @State private var form = NewAPIAccount()
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add API account").font(.headline)
            Form {
                TextField("Name", text: $form.label)
                TextField("Base URL", text: $form.baseURL, prompt: Text("https://api.example.com/anthropic"))
                SecureField("API key", text: $form.token)
                TextField("Model (optional)", text: $form.model)
                Toggle("Fallback — ask before using", isOn: $form.isFallback)
            }
            Text("The key is saved in the macOS Keychain, never in a file.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: close).keyboardShortcut(.cancelAction)
                Button("Add") {
                    saving = true
                    Task {
                        let added = await model.addAPI(form)
                        saving = false
                        if added { form = NewAPIAccount(); close() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!form.isComplete || saving)
            }
        }
        .padding()
        .frame(width: 420)
    }
}
