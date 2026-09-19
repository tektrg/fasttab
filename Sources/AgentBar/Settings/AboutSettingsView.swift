import SwiftUI

/// "About" tab: which app and version this is, and where its data comes from.
struct AboutSettingsView: View {
    var body: some View {
        Form {
            Section {
                row("Name", "AgentBar")
                row("Version", appVersion)
                row("Bundle ID", AgentBarIdentity.bundleIdentifier)
            }
            Section {
                Text("AgentBar shows the agents running in herdr, grouped by what they need from you. Status comes from the chief dashboard running on this Mac; AgentBar switches you to an agent's tab and, only when you press a key or button, finishes an agent (Done) or sends your answer to its open question.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    private var appVersion: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        return build.isEmpty || build == short ? short : "\(short) (\(build))"
    }
}
