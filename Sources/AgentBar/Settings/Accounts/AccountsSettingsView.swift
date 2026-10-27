import SwiftUI

/// Settings › Accounts: the Claude accounts of `accounts.json` (owned by the dashboard), in their
/// rotation order. Add a subscription or API account, or remove one (AccountAddViews.swift).
/// Login rows get "Log in", which opens a herdr tab `claude-login-<id>`
/// running `claude /login`; the user finishes the browser sign-in there. Reordering is slice 2.
@MainActor
final class AccountsSettingsModel: ObservableObject {
    @Published private(set) var accounts: DashboardAccounts?
    @Published private(set) var loadError: String?
    @Published private(set) var isLoading = false
    /// Per account id: the last Log in outcome, shown under its row.
    @Published private(set) var loginResults: [String: AccountActionOutcome] = [:]
    @Published private(set) var loggingIn: Set<String> = []

    private let endpoint: () -> DashboardEndpoint
    private let transport: DashboardTransport

    init(endpoint: @escaping () -> DashboardEndpoint,
         transport: DashboardTransport = URLSessionDashboardTransport()) {
        self.endpoint = endpoint
        self.transport = transport
    }

    func reload() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let (body, statusCode) = try await transport.response(for: endpoint().accountsRequest)
            guard statusCode != 404 else {
                loadError = "This dashboard has no accounts yet — update it."
                return
            }
            accounts = try JSONDecoder().decode(DashboardAccounts.self, from: body)
            loadError = nil
        } catch is DecodingError {
            loadError = "The dashboard sent an unreadable accounts reply."
        } catch {
            loadError = "Can't reach the status dashboard."
        }
    }

    func logIn(_ id: String) async {
        loggingIn.insert(id)
        defer { loggingIn.remove(id) }
        loginResults[id] = await AccountActionOutcome.perform(endpoint().accountLoginRequest(id: id),
                                                              transport: transport)
    }

    /// Last add/remove outcome, shown above the list ("finish sign-in in tab …" or an error).
    @Published private(set) var editNotice: AccountEditNotice?

    func addSubscription(label: String) async {
        do {
            let (body, statusCode) = try await transport.response(
                for: endpoint().addSubscriptionAccountRequest(label: label))
            let reply = try JSONDecoder().decode(AddSubscriptionResponse.self, from: body)
            if reply.ok == true, let id = reply.account?.id {
                editNotice = .info("Added \(label). Finish sign-in in tab claude-login-\(id), then Refresh.")
            } else {
                editNotice = .error(reply.error ?? "The dashboard refused (HTTP \(statusCode)).")
            }
        } catch {
            editNotice = .error("Can't reach the status dashboard.")
        }
        await reload()
    }

    /// True when added (the sheet closes); the key is dropped from memory with the form.
    func addAPI(_ form: NewAPIAccount) async -> Bool {
        let outcome = await AccountActionOutcome.perform(endpoint().addAPIAccountRequest(form), transport: transport)
        editNotice = outcome == .succeeded ? .info("Added \(form.label). Its key is in the Keychain.") : outcome.notice
        await reload()
        return outcome == .succeeded
    }

    func remove(_ account: DashboardAccounts.Account) async {
        let outcome = await AccountActionOutcome.perform(endpoint().removeAccountRequest(id: account.id),
                                                         transport: transport)
        editNotice = outcome == .succeeded ? .info("Removed \(account.displayLabel).") : outcome.notice
        await reload()
    }
}

struct AccountsSettingsView: View {
    @StateObject private var model: AccountsSettingsModel

    init(settings: AgentBarSettings) {
        _model = StateObject(wrappedValue: AccountsSettingsModel { [settings] in
            DashboardEndpoint(baseURL: settings.dashboardBaseURL)
        })
    }

    var body: some View {
        Form {
            if let loadError = model.loadError {
                Section {
                    PersonaNotice(text: loadError)
                    Button("Try again") { Task { await model.reload() } }
                }
            } else if let accounts = model.accounts {
                AccountAddSection(model: model)
                Section {
                    if accounts.accounts.isEmpty {
                        Text("No accounts in accounts.json.").foregroundStyle(.secondary)
                    }
                    ForEach(accounts.accounts, id: \.id) { account in
                        AccountRow(account: account, pendingApprovalID: accounts.pendingApproval?.id, model: model)
                    }
                } footer: {
                    Text("Rotation order, top first. Log in opens a terminal tab named claude-login-<id>; finish the sign-in there, then Refresh.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Section { ProgressView().controlSize(.small) }
            }
        }
        .formStyle(.grouped)
        .toolbar {
            Button { Task { await model.reload() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                .disabled(model.isLoading)
        }
        .task { await model.reload() }
    }
}

private struct AccountRow: View {
    let account: DashboardAccounts.Account
    let pendingApprovalID: String?
    @ObservedObject var model: AccountsSettingsModel
    @State private var confirmRemove = false

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(account.displayLabel).fontWeight(.semibold)
                Text([account.kind, account.tier].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
                if let status = account.statusText(pendingApprovalID: pendingApprovalID, now: Date()) {
                    Text(status).font(.caption)
                }
                outcome
            }
            Spacer()
            Button(role: .destructive) { confirmRemove = true } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .help("Remove this account")
                .confirmationDialog("Remove \(account.displayLabel)?", isPresented: $confirmRemove) {
                    Button("Remove", role: .destructive) { Task { await model.remove(account) } }
                } message: {
                    Text("Rotation stops using it. A saved API key is deleted; a sign-in folder stays on disk.")
                }
            if account.canLogIn {
                Button(account.loggedIn == true ? "Re-log in" : "Log in") {
                    Task { await model.logIn(account.id) }
                }
                .disabled(model.loggingIn.contains(account.id))
            }
        }
    }

    @ViewBuilder private var outcome: some View {
        switch model.loginResults[account.id] {
        case .succeeded?:
            Text("Opened tab claude-login-\(account.id) — finish the sign-in there.")
                .font(.caption).foregroundStyle(.green)
        case .failed(let message)?:
            PersonaNotice(text: message)
        case nil:
            EmptyView()
        }
    }
}
