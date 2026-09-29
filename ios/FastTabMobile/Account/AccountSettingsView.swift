import IndieAccount
import SwiftUI

/// More → "theindie account": sign in with Apple, who is signed in, sign out, delete account.
/// Transcripts in the reader need this account.
struct AccountSettingsView: View {
    @Environment(AccountSession.self) private var accountSession
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var confirmingDelete = false
    @State private var appleReauthorization = AppleReauthorization()

    var body: some View {
        Form {
            switch accountSession.state {
            case .restoring:
                Section { ProgressView("Checking your account…") }
            case .signedOut:
                signedOutSection
            case let .signedIn(profile):
                signedInSections(profile)
            }
            if let message = errorMessage ?? accountSession.lastError?.userMessage {
                Section { Text(message).foregroundStyle(.red) }
            }
        }
        .navigationTitle("theindie account")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(isWorking)
        .confirmationDialog("Delete your account?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete account", role: .destructive) {
                run { await deleteAccountAfterAppleConfirms() }
            }
        } message: {
            Text("You'll confirm with Apple first. Your theindie account is removed from the server. Your tabs, bookmarks and reading on this phone stay. This cannot be undone.")
        }
    }

    private var signedOutSection: some View {
        Section {
            AppleSignInButton()
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
        } footer: {
            Text(accountSession.hasStoredSession
                 ? "Couldn't reach your account. Sign in again, or try later."
                 : "Sign in to get YouTube transcripts in the reader.")
        }
    }

    @ViewBuilder
    private func signedInSections(_ profile: OwnProfile) -> some View {
        Section("Signed in") {
            LabeledContent("Name", value: profile.displayName ?? "Not shared")
            LabeledContent("Email", value: profile.isPrivateEmail ? "Hidden by Apple" : (profile.email ?? "Not shared"))
        }
        Section {
            Button("Sign out") { run { await accountSession.signOut(); return true } }
        }
        Section {
            Button("Delete account", role: .destructive) { confirmingDelete = true }
        }
    }

    /// Apple confirms it's the account owner (fresh code), then the server deletes the account.
    /// Cancelling Apple's sheet quietly does nothing.
    private func deleteAccountAfterAppleConfirms() async -> Bool {
        switch await appleReauthorization.requestAuthorizationCode() {
        case let .authorized(code):
            return await accountSession.deleteAccount(authorizationCode: code)
        case .cancelled:
            return true
        case .failed:
            accountSession.lastError = .accountDeletionNotConfirmed
            return false
        }
    }

    /// Runs an account action with the screen disabled; shows its failure message here.
    private func run(_ action: @escaping () async -> Bool) {
        Task {
            isWorking = true
            defer { isWorking = false }
            errorMessage = nil
            accountSession.lastError = nil
            if !(await action()) {
                errorMessage = accountSession.lastError?.userMessage ?? "Something went wrong. Try again."
                accountSession.lastError = nil
            }
        }
    }
}

/// The More-tab row's subtitle: who is signed in, or why to sign in.
extension AccountSession {
    var moreRowSubtitle: String {
        switch state {
        case .restoring: "Checking…"
        case .signedOut: "Sign in for YouTube transcripts"
        case let .signedIn(profile): "Signed in" + (profile.displayName.map { " as \($0)" } ?? "")
        }
    }
}
