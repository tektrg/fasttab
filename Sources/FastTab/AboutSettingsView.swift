import SwiftUI
import AppKit

/// "About" tab of Settings: support contact and the installed version.
struct AboutSettingsView: View {
    @EnvironmentObject var licenseService: LicenseService
    @State private var didCopySupportEmail = false

    private let supportEmailAddress = "yourfriend@theindie.app"

    var body: some View {
        Form {
            Section("Feedback & Support") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Need help or want to share feedback?")
                        .font(.callout.weight(.medium))
                    Text("Email the founder directly. Bug reports, rough edges, and workflow ideas are all welcome.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 8) {
                    Button("Email \(supportEmailAddress)") {
                        licenseService.openSupport()
                    }

                    Button {
                        copySupportEmailAddress()
                    } label: {
                        Image(systemName: didCopySupportEmail ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .help(didCopySupportEmail ? "Copied" : "Copy email address")
                    .accessibilityLabel(didCopySupportEmail ? "Copied support email address" : "Copy support email address")
                }
            }

            Section {
                HStack {
                    Spacer()
                    Text("Version \(appVersion)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .listRowBackground(Color.clear)
            }
        }
        .formStyle(.grouped)
    }

    private var appVersion: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        if !build.isEmpty && build != short {
            return "\(short) (\(build))"
        }
        return short
    }

    private func copySupportEmailAddress() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(supportEmailAddress, forType: .string)
        didCopySupportEmail = true

        Task {
            try? await Task.sleep(for: .seconds(1.5))
            didCopySupportEmail = false
        }
    }
}
