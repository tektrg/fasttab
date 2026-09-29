import SwiftUI
import AppKit

// The onboarding steps that ask the user to set something up outside
// FastTab: the browser extension, Safari's Full Disk Access, and the
// shortcut. Split from `OnboardingView.swift` to keep both files small.

// MARK: - Recommended: browser extension

struct ExtensionInstallStep: View {
    @ObservedObject private var permissions = AutomationPermissionStore.shared
    @Binding var didAutoAdvance: Bool
    let onContinue: () -> Void
    /// Advances only if this step is still showing when the delay fires.
    let onAutoAdvance: () -> Void

    private var isExtensionUsable: Bool { !permissions.usableExtensionAppNames.isEmpty }
    @Environment(\.openURL) private var openURL
    /// `.key` while onboarding is the key window of the active app.
    @Environment(\.controlActiveState) private var controlActiveState

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 12)

            OnboardingHeroExtension(state: ExtensionHeroState(setupState: permissions.extensionSetupState))
                .padding(.bottom, 10)

            Text("Sharper Recents, instant tabs")
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .padding(.bottom, 6)

            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 36)
                .padding(.bottom, 18)

            OnboardingBenefitsView(benefits: OnboardingBenefit.extensionBenefits)
                .padding(.horizontal, 44)
                .padding(.bottom, 20)

            primaryAction
                .padding(.bottom, 8)

            if permissions.extensionSetupState == .waiting {
                Text("Add it in each browser profile you use.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.bottom, 8)
            }

            ExtensionSetupStatusView()

            if !isExtensionUsable {
                Button("Skip for now", action: onContinue)
                    .buttonStyle(.plain)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)
        }
        .onAppear {
            scheduleAutoAdvanceIfConnected()
        }
        .onChange(of: permissions.usableExtensionAppNames) { _, _ in
            scheduleAutoAdvanceIfConnected()
        }
        .onChange(of: controlActiveState) { _, _ in
            scheduleAutoAdvanceIfConnected()
        }
    }

    /// Already set up (e.g. replaying onboarding): confirm instead of selling.
    private var subtitle: String {
        isExtensionUsable
            ? "The FastTab extension is set up — here's what it adds."
            : "Add the free FastTab extension to Chrome, Edge or Brave. FastTab works without it — this makes it better."
    }

    /// Advances itself once the bridge handshakes — install the extension in
    /// Chrome and this step finishes on its own, after the hero's success beat.
    /// The handshake usually lands while Chrome is in front, so it waits for
    /// onboarding to be back in front, where the paused beat then plays.
    private func scheduleAutoAdvanceIfConnected() {
        guard !didAutoAdvance, isExtensionUsable, controlActiveState == .key else { return }
        didAutoAdvance = true
        Task { @MainActor in
            try? await Task.sleep(for: ExtensionHeroState.autoAdvanceDelay)
            onAutoAdvance()
        }
    }

    /// One prominent action for where setup stands: move on once usable,
    /// switch the setting on when it's installed but turned off, otherwise
    /// get (or update) the extension.
    private var primaryAction: some View {
        let action: (title: String, symbolName: String, perform: () -> Void)
        switch permissions.extensionSetupState {
        case .usable:
            action = ("Continue", "arrow.right.circle.fill", onContinue)
        case .turnedOff:
            action = ("Turn on the extension", "power.circle.fill", { permissions.turnOnExtensionFeature() })
        case .versionMismatch, .waiting:
            action = ("Get the extension", "arrow.down.circle.fill", { openURL(FastTabExtensionIdentity.chromeWebStoreURL) })
        }
        return Button(action: action.perform) {
            Label(action.title, systemImage: action.symbolName)
                .font(.headline)
                .frame(width: 200)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }
}

// MARK: - Step 4: Safari permission (conditional)

struct SafariPermissionStep: View {
    @AppStorage(SafariBackend.includeFDADataDefaultsKey) private var includeSafariFDAData: Bool = SafariBackend.includeFDADataDefaultValue
    let onContinue: () -> Void
    /// Whether Full Disk Access is on. Injectable so layout tests can render
    /// the step without the app-wide `AppState` (its CloudKit setup traps in tests).
    var canReadSafariProtectedData: () -> Bool = { AppState.shared.browserService.canReadSafariProtectedData() }

    @State private var fdaInitiallyGranted: Bool = false
    @State private var fdaGrantedNow: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 12)

            OnboardingHeroSafari(state: SafariHeroState(isGranted: fdaGrantedNow))
                .padding(.bottom, 14)

            Text("Safari needs Full Disk Access")
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
                .padding(.bottom, 8)

            Text("Without it, Safari tabs still work — but bookmarks, history, and favicons won't appear.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .padding(.horizontal, 32)
                .padding(.bottom, 22)

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
            .padding(.horizontal, 28)
            .padding(.bottom, 16)

            if fdaGrantedNow && !fdaInitiallyGranted {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Full Disk Access granted — FastTab restarts when you finish.")
                        .font(.caption)
                    Spacer()
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 12)
            }

            HStack(spacing: 14) {
                Button("Skip") { finish(continued: false) }
                .buttonStyle(.plain)
                .font(.callout)
                .foregroundStyle(.tertiary)

                Button {
                    finish(continued: true)
                } label: {
                    Text("Continue")
                        .font(.headline)
                        .frame(width: 160)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }

            Spacer(minLength: 12)
        }
        .onAppear {
            fdaInitiallyGranted = canReadSafariProtectedData()
            fdaGrantedNow = fdaInitiallyGranted
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            fdaGrantedNow = canReadSafariProtectedData()
        }
    }

    private func finish(continued: Bool) {
        let granted = continued && canReadSafariProtectedData()
        if let choice = SafariBackend.onboardingFDADataChoice(continued: continued, fullDiskAccessGranted: granted) {
            includeSafariFDAData = choice
        }
        onContinue()
    }

    private func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Step 5: Shortcut

struct ShortcutStep: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var shortcutStore = ShortcutStore.shared
    @ObservedObject private var edgeReveal = EdgeRevealStore.shared
    @ObservedObject private var permissions = AutomationPermissionStore.shared
    let onDismiss: (Bool) -> Void
    /// Injectable for the same reason as `SafariPermissionStep.canReadSafariProtectedData`.
    var isRestartNeeded: () -> Bool = { OnboardingWindowController.shared.isRestartNeededToApplyChoices }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 12)

            OnboardingHeroShortcut(keycaps: shortcutStore.heroKeycaps)
                .padding(.bottom, 12)

            Text(edgeReveal.style == .off ? "Your Shortcut" : "Your Backup Shortcut")
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .padding(.bottom, 6)

            Text(shortcutStepSubtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
                .padding(.bottom, 16)

            ShortcutRecorderView(store: shortcutStore)
                .padding(.bottom, 8)

            Text("You can change this later in Settings…")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 14)

            automationNote
                .padding(.horizontal, 40)
                .padding(.bottom, 16)

            if isRestartNeeded() {
                Text("FastTab will restart to apply your choices.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.bottom, 10)
            }

            HStack(spacing: 14) {
                Button("Maybe Later") {
                    onDismiss(false)
                }
                .buttonStyle(.plain)
                .font(.callout)
                .foregroundStyle(.tertiary)

                Button {
                    onDismiss(true)
                } label: {
                    Label("Open FastTab", systemImage: "arrow.right.circle.fill")
                        .font(.headline)
                        .frame(width: 168)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }

            Spacer()
        }
    }

    private var shortcutStepSubtitle: String {
        edgeReveal.style == .off
            ? "Press this from any app to open FastTab:"
            : "Hovering opens FastTab, but this works too, from any app:"
    }

    @ViewBuilder
    private var automationNote: some View {
        if !permissions.usableExtensionAppNames.isEmpty {
            // A connected companion extension covers Chromium tab switching, so
            // the Automation prompt this note warns about never appears for it.
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "puzzlepiece.extension")
                    .font(.caption)
                    .foregroundStyle(.green)
                    .padding(.top, 1)

                Text("Chrome, Edge & Brave tab switching uses the companion extension — no macOS permission prompt needed.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.leading)
            }
        } else {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 1)

                Text("The first time you search, macOS will ask to allow FastTab to control your browser. Click **Allow** to enable tab switching.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.leading)
            }
        }
    }
}
