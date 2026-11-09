import FastTabWebReader
import SwiftUI

/// Settings > Experimental: features that are off by default (mirrors the iPhone's
/// More > Experimental section).
struct ExperimentalSettingsView: View {
    @ObservedObject private var webReader = WebReaderController.shared
    @State private var pairingCode = ""
    @State private var isPairing = false

    var body: some View {
        Form {
            Section {
                Toggle("Web Reader", isOn: Binding(
                    get: { webReader.isEnabled },
                    set: { webReader.setEnabled($0) }))
            } header: {
                Text("Experimental")
            } footer: {
                Text("Read your tabs, bookmarks, FastTab List and saved articles at fasttab.theindie.app/web, end-to-end encrypted. Highlights made there come back here and to your iPhone. Turning this off deletes the web copy.")
            }

            if webReader.isEnabled {
                if webReader.isSignedIn {
                    pairingSection
                    browsersSection
                } else {
                    Section("Account") {
                        Button("Sign in with Apple…") { webReader.signIn() }
                        Text("Needed once, so only your own browsers can read this Mac's data.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if !webReader.status.isEmpty {
                    Section { Text(webReader.status).font(.caption).foregroundStyle(.secondary) }
                }
            }
            if let error = webReader.errorMessage {
                Section { Text(error).font(.caption).foregroundStyle(.red) }
            }
        }
        .formStyle(.grouped)
    }

    private var pairingSection: some View {
        Section("Pair a browser") {
            TextField("Pairing code", text: $pairingCode, prompt: Text("8 characters, shown in the browser"))
            Button(isPairing ? "Pairing…" : "Approve") {
                isPairing = true
                Task {
                    await webReader.approvePairing(input: pairingCode)
                    isPairing = false
                    if webReader.errorMessage == nil { pairingCode = "" }
                }
            }
            .disabled(isPairing || pairingCode.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private var browsersSection: some View {
        Section("Paired browsers") {
            if webReader.pairedBrowsers.isEmpty {
                Text("None yet. Open fasttab.theindie.app/web to get a code.").foregroundStyle(.secondary)
            }
            ForEach(webReader.pairedBrowsers) { device in
                HStack {
                    VStack(alignment: .leading) {
                        Text(device.name ?? "Browser")
                        if let seen = device.lastSeenAt {
                            Text("Last seen \(seen.formatted(.relative(presentation: .named)))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("Unpair", role: .destructive) { Task { await webReader.unpair(device) } }
                }
            }
        }
    }
}
