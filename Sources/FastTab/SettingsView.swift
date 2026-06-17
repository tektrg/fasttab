import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var licenseService: LicenseService
    @StateObject private var launchAtLogin = LaunchAtLoginService.shared
    @ObservedObject private var shortcutStore = ShortcutStore.shared
    @ObservedObject private var sourceSelection = SourceSelectionStore.shared

    @AppStorage("FastTab.safari.includeFDAData") private var includeSafariFDAData: Bool = false
    @AppStorage(CommandBarAppearance.outerPanelKey) private var outerPanelEnabled: Bool = false

    @State private var fdaInitiallyGranted: Bool = false
    @State private var fdaGrantedNow: Bool = false
    @State private var licenseKey: String = ""
    @State private var didCopySupportEmail: Bool = false

    private let supportEmailAddress = "yourfriend@theindie.app"

    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch at login", isOn: Binding(
                    get: { launchAtLogin.isEnabled },
                    set: { launchAtLogin.setEnabled($0) }
                ))

                if let errorMessage = launchAtLogin.errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if #available(macOS 26.0, *) {
                Section("Appearance") {
                    Toggle("Glass background panel", isOn: $outerPanelEnabled)
                }
            }

            Section("Shortcut") {
                HStack {
                    Text("Global shortcut")
                    Spacer()
                    ShortcutRecorderView(store: shortcutStore)
                }

                if let issue = appState.globalShortcutRegistrationIssue {
                    Text(issue)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section("Sources") {
                ForEach(SearchSource.allCases) { source in
                    Toggle(source.displayName, isOn: Binding(
                        get: { sourceSelection.isEnabled(source) },
                        set: { sourceSelection.setEnabled(source, $0) }
                    ))
                    .disabled(!source.isInstalled)

                    if !source.isInstalled {
                        Text("Not installed on this Mac.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }

                if sourceSelection.needsRestartToApply {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.clockwise.circle.fill")
                            .foregroundStyle(.orange)
                        Text("Restart FastTab to apply source changes.")
                            .font(.callout)
                        Spacer()
                        Button("Restart") {
                            restartApp()
                        }
                        .controlSize(.small)
                    }
                }
            }

            Section("License") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(licenseStatusTitle)
                        .font(.callout.weight(.medium))
                    Text(licenseStatusDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack {
                    SecureField("License key", text: $licenseKey)
                    Button(licenseService.isActivating ? "Activating…" : "Activate") {
                        Task {
                            await licenseService.activateLicense(key: licenseKey)
                            if licenseService.snapshot.license != nil {
                                licenseKey = ""
                            }
                        }
                    }
                    .disabled(licenseService.isActivating || licenseKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                HStack {
                    Button("Buy FastTab") {
                        licenseService.openCheckout(source: .settings)
                    }
                    Button("Manage License") {
                        licenseService.openManageLicense()
                    }
                    if licenseService.snapshot.license != nil {
                        Button("Remove License") {
                            licenseService.clearLicense()
                        }
                    }
                }

                if let lastErrorMessage = licenseService.snapshot.lastErrorMessage {
                    Text(lastErrorMessage)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

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

            if sourceSelection.isEnabled(.safari) {
            Section("Safari") {
                Toggle("Include Safari bookmarks and history", isOn: $includeSafariFDAData)

                if includeSafariFDAData {
                    Text("Requires Full Disk Access. Without it, Safari tabs still work but bookmarks, history, and favicons will not appear.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(alignment: .center, spacing: 14) {
                        AppIconDragView(size: 64, onClick: openFullDiskAccessSettings)
                            .frame(width: 64, height: 64)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Drag this icon into Full Disk Access")
                                .font(.callout.weight(.medium))
                            Text("Or click the icon to open System Settings.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 4)

                    if fdaGrantedNow && !fdaInitiallyGranted {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text("Full Disk Access granted — restart FastTab to apply.")
                                .font(.callout)
                            Spacer()
                            Button("Restart") {
                                restartApp()
                            }
                            .controlSize(.small)
                        }
                    }
                }

                HStack(spacing: 8) {
                    Text("Safari automation:")
                        .foregroundStyle(.secondary)
                    Text(safariAutomationStatusText)
                        .font(.callout.weight(.medium))
                    Spacer()
                    Button("Recheck") {
                        appState.browserService.recheckSafariAutomation()
                    }
                    .controlSize(.small)
                }
                .font(.caption)
            }
            } // if sourceSelection.isEnabled(.safari)

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
        .frame(width: 480)
        .frame(minHeight: 360)
        .onAppear {
            fdaInitiallyGranted = appState.browserService.canReadSafariProtectedData()
            fdaGrantedNow = fdaInitiallyGranted
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            fdaGrantedNow = appState.browserService.canReadSafariProtectedData()
        }
    }

    private var appVersion: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        if !build.isEmpty && build != short {
            return "\(short) (\(build))"
        }
        return short
    }

    private func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
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

    private func restartApp() {
        let bundleURL = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: bundleURL, configuration: config) { _, _ in
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
        }
    }

    private var safariAutomationStatusText: String {
        switch appState.browserService.safariAutomationStatus {
        case .notInstalled:
            return "Safari not installed"
        case .granted:
            return "granted"
        case .denied:
            return "denied"
        case .notDetermined:
            return "not yet requested"
        }
    }

    private var licenseStatusTitle: String {
        switch licenseService.snapshot.access {
        case .trial(let daysRemaining):
            return "Trial active: \(daysRemaining) day\(daysRemaining == 1 ? "" : "s") left"
        case .licensed(let tier):
            return "\(tier.displayName) license active"
        case .expiredTrial:
            return "Trial ended"
        case .revoked:
            return "License needs attention"
        case .paidMajorUpgradeRequired:
            return "Paid upgrade required"
        }
    }

    private var licenseStatusDetail: String {
        if let license = licenseService.snapshot.license {
            let activationText = license.activationLimit.map { "\(license.activationUsage)/\($0) activations" } ?? "\(license.activationUsage) activations"
            return "\(license.displayKey) · \(activationText) · Last checked \(license.lastValidatedAt.formatted(date: .abbreviated, time: .shortened))"
        }

        switch licenseService.snapshot.access {
        case .trial:
            return "FastTab is fully unlocked during the 7-day trial."
        case .expiredTrial:
            return "Buy once or paste a Polar license key to continue using FastTab."
        case .revoked:
            return "This license is revoked or disabled. Contact support if this looks wrong."
        case .paidMajorUpgradeRequired(let tier):
            return "The \(tier.displayName) license does not include this paid major version."
        case .licensed:
            return "FastTab is unlocked."
        }
    }
}
