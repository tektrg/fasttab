import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var licenseService: LicenseService
    @StateObject private var launchAtLogin = LaunchAtLoginService.shared
    @ObservedObject private var shortcutStore = ShortcutStore.shared
    @ObservedObject private var sourceSelection = SourceSelectionStore.shared
    @ObservedObject private var edgeReveal = EdgeRevealStore.shared
    @ObservedObject private var webAppCatalog = InstalledWebAppCatalog.shared
    @ObservedObject private var webAppRouting = WebAppRoutingStore.shared

    @AppStorage("FastTab.safari.includeFDAData") private var includeSafariFDAData: Bool = false
    @AppStorage(CommandBarAppearance.outerPanelKey) private var outerPanelEnabled: Bool = false
    @AppStorage(CommandBarAppearance.resultRowStyleKey) private var resultRowStyle: ResultRowStyle = .minimal
    @AppStorage(CommandBarAppearance.quickOpenItemLimitKey) private var quickOpenItemLimit: Int = 5
    @AppStorage(CommandBarAppearance.menuBarIconVisibleKey) private var showMenuBarIcon: Bool = true
    @AppStorage(CommandBarAppearance.helperPanelVisibleKey) private var showHelperPanel: Bool = true

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

                // The gear icon that opens this window lives in the helper
                // panel, and "Settings…" lives in the menu bar menu — each is
                // the other's fallback. Refusing to disable the second one
                // keeps at least one path back into Settings once the icon
                // and panel are both off.
                Toggle("Show menu bar icon", isOn: Binding(
                    get: { showMenuBarIcon },
                    set: { newValue in
                        guard newValue || showHelperPanel else { return }
                        showMenuBarIcon = newValue
                    }
                ))

                if !showMenuBarIcon {
                    Text("The global shortcut still opens FastTab. Reopen this settings window from the helper panel's gear icon.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Toggle("Show helper panel", isOn: Binding(
                    get: { showHelperPanel },
                    set: { newValue in
                        guard newValue || showMenuBarIcon else { return }
                        showHelperPanel = newValue
                    }
                ))

                Text("The row of hints and the shortcut recorder shown at the bottom of the command bar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Appearance") {
                Toggle("Background", isOn: $outerPanelEnabled)

                Picker("Result rows", selection: $resultRowStyle) {
                    ForEach(ResultRowStyle.allCases) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                .pickerStyle(.segmented)

                Stepper(
                    "Quick-open items: \(quickOpenItemLimit)",
                    value: $quickOpenItemLimit,
                    in: CommandBarLayout.minQuickOpenItemLimit...CommandBarLayout.maxQuickOpenItemLimit
                )

                Text("Recent tabs shown when FastTab opens with an empty search. Automatically reduced to fit smaller screens.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Trigger") {
                Picker("Hover to open", selection: Binding(
                    get: { edgeReveal.style },
                    set: { edgeReveal.update($0) }
                )) {
                    ForEach(EdgeRevealStyle.allCases) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                .pickerStyle(.menu)

                if edgeReveal.style != .off {
                    Text("Hover the \(edgeReveal.style.displayName.lowercased()) to open FastTab instantly. Runs a background mouse-position listener whenever this isn't Off.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
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

            Section("Open as App") {
                if webAppCatalog.apps.isEmpty {
                    Text("No installed web apps found. Use a browser's \"Install as app\" option to see it here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(webAppCatalog.apps) { app in
                        let routeKey = webAppRouteKeyString(for: app.homeURL)
                        let dormant = isWebAppDormant(app)

                        Toggle(app.name, isOn: Binding(
                            get: { routeKey.map { webAppRouting.decision(for: $0) == .enabled } ?? false },
                            set: { newValue in
                                guard let routeKey else { return }
                                webAppRouting.setDecision(newValue ? .enabled : .declined, for: routeKey)
                            }
                        ))
                        .disabled(dormant)

                        if dormant {
                            Text("\(app.browserAppName) isn't an enabled source above, so links can never route here.")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }

                    Text("Enabled sites reopen from history or bookmarks in the app's own window instead of a new tab.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
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
            webAppCatalog.rescanIfNeeded()
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

    private func isWebAppDormant(_ app: InstalledWebApp) -> Bool {
        !SearchSource.allCases.contains { $0.displayName == app.browserAppName && sourceSelection.isEnabled($0) }
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
