import SwiftUI
import AppKit
import CommandBarKit

private let onboardingCompletedKey = "onboarding.v1.completed"

// MARK: - Coordinator

@MainActor
final class OnboardingWindowController: NSObject {
    static let shared = OnboardingWindowController()
    /// Shared by the menu bar item and Settings > About.
    static let replayMenuTitle = "Replay Onboarding…"

    private var window: NSWindow?
    /// Full Disk Access state when this process started (the controller is
    /// first touched at launch). Safari's protected data only becomes
    /// readable after a relaunch, so a grant during onboarding needs one.
    private let safariDataReadableAtLaunch = AppState.shared.browserService.canReadSafariProtectedData()

    var isNeeded: Bool {
        !UserDefaults.standard.bool(forKey: onboardingCompletedKey)
    }

    /// Onboarding choices that only take effect in a fresh process: source
    /// toggles (backends are built once at launch — see `BrowserTabService.init`)
    /// and a Full Disk Access grant for Safari bookmarks/history.
    var isRestartNeededToApplyChoices: Bool {
        let sources = SourceSelectionStore.shared
        if sources.needsRestartToApply { return true }
        guard sources.isEnabled(.safari), SafariBackend.isFDADataIncluded(), !safariDataReadableAtLaunch else { return false }
        return AppState.shared.browserService.canReadSafariProtectedData()
    }

    /// Opens onboarding from the first step. Also used to replay it later
    /// (menu bar / Settings); replaying only re-shows the steps — existing
    /// settings are kept and pre-filled.
    func show() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let view = OnboardingView { [weak self] shouldOpenBar in
            self?.dismiss(andOpenBar: shouldOpenBar)
        }
        .environmentObject(AppState.shared)

        let controller = NSHostingController(rootView: view)
        controller.view.wantsLayer = true

        let win = NSWindow(contentViewController: controller)
        Self.configureOnboardingWindow(win)
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        window = win
    }

    static func configureOnboardingWindow(_ win: NSWindow) {
        win.styleMask = [.titled, .fullSizeContentView]
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = true
        win.isMovable = false
        win.isMovableByWindowBackground = false

        [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].forEach {
            win.standardWindowButton($0)?.isHidden = true
        }

        win.setContentSize(NSSize(width: 440, height: 520))
        win.center()
    }

    private func dismiss(andOpenBar: Bool) {
        let needsRestart = isRestartNeededToApplyChoices
        window?.close()
        window = nil
        UserDefaults.standard.set(true, forKey: onboardingCompletedKey)
        if needsRestart {
            restartFastTab(openCommandBarAfterRelaunch: andOpenBar)
            return
        }
        if andOpenBar {
            AppState.shared.showCommandBar(openedBy: .mouse)
        }
    }
}

// MARK: - Step model

/// The sequence of steps shown during onboarding. `safariPermission` is
/// conditional on Safari being in the user's selected source set, so the
/// `steps()` builder reads from `SourceSelectionStore` rather than being a
/// fixed list.
private enum OnboardingStep: Hashable {
    case welcome
    case triggerStyle
    case sources
    case extensionInstall
    case safariPermission
    case iPhoneApp
    case shortcut
}

// MARK: - Root View

struct OnboardingView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var selectionStore = SourceSelectionStore.shared
    let onDismiss: (Bool) -> Void

    @State private var stepIndex: Int = 0
    /// Lifted out of `ExtensionInstallStep` so stepping Back onto it doesn't
    /// auto-advance the user forward again.
    @State private var didAutoAdvancePastExtension = false

    private var steps: [OnboardingStep] {
        var list: [OnboardingStep] = [.welcome, .triggerStyle, .sources]
        // Recommended (skippable) step — only meaningful when a Chromium browser is in play.
        if ChromiumBrowserSpec.all.contains(where: { selectionStore.enabled.contains($0.source) }) {
            list.append(.extensionInstall)
        }
        if selectionStore.enabled.contains(.safari) {
            list.append(.safariPermission)
        }
        list.append(.iPhoneApp)
        list.append(.shortcut)
        return list
    }

    /// Current step, clamped to the live `steps` list. The list shrinks when
    /// the user unchecks Safari on the picker step, so the index can momentarily
    /// point past the end — clamp rather than crash.
    private var currentStep: OnboardingStep {
        steps[clampedStepIndex]
    }

    private var clampedStepIndex: Int {
        min(max(stepIndex, 0), steps.count - 1)
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.ultraThinMaterial)

            VStack(spacing: 0) {
                Group {
                    switch currentStep {
                    case .welcome:
                        WelcomeStep(onContinue: advance)
                            .transition(stepTransition)
                    case .triggerStyle:
                        TriggerStyleStep(onContinue: advance)
                            .transition(stepTransition)
                    case .sources:
                        SourcePickerStep(
                            store: selectionStore,
                            onContinue: advance
                        )
                        .transition(stepTransition)
                    case .extensionInstall:
                        ExtensionInstallStep(
                            didAutoAdvance: $didAutoAdvancePastExtension,
                            onContinue: advance,
                            onAutoAdvance: { advance(ifStillOn: .extensionInstall) }
                        )
                            .transition(stepTransition)
                    case .safariPermission:
                        SafariPermissionStep(onContinue: advance)
                            .transition(stepTransition)
                    case .iPhoneApp:
                        OnboardingIPhoneStep(onContinue: advance)
                            .transition(stepTransition)
                    case .shortcut:
                        ShortcutStep(onDismiss: onDismiss)
                            .transition(stepTransition)
                    }
                }
                .animation(.spring(response: 0.38, dampingFraction: 0.82), value: stepIndex)

                stepDots
                    .padding(.bottom, 20)
            }
        }
        .overlay(alignment: .topLeading) {
            if clampedStepIndex > 0 {
                backButton
            }
        }
        .frame(width: 440, height: 520)
    }

    private var stepTransition: AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .offset(x: 32)),
            removal: .opacity.combined(with: .offset(x: -32))
        )
    }

    private func advance() {
        let count = steps.count
        withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
            stepIndex = min(clampedStepIndex + 1, count - 1)
        }
    }

    /// Delayed advances call this so a Continue/Back tapped in the meantime
    /// wins — otherwise the late advance skips a step or undoes the Back.
    private func advance(ifStillOn step: OnboardingStep) {
        guard currentStep == step else { return }
        advance()
    }

    /// Steps back through the live `steps` list, so conditional steps
    /// (extension, Safari) are revisited only while they still apply.
    private func goBack() {
        withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
            stepIndex = max(clampedStepIndex - 1, 0)
        }
    }

    private var backButton: some View {
        Button(action: goBack) {
            Label("Back", systemImage: "chevron.left")
                .font(.callout)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .keyboardShortcut(.leftArrow, modifiers: .command)
        .padding(.top, 16)
        .padding(.leading, 18)
    }

    private var stepDots: some View {
        let count = steps.count
        let active = min(max(stepIndex, 0), count - 1)
        return HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { i in
                Capsule()
                    .fill(i == active ? Color.primary.opacity(0.7) : Color.primary.opacity(0.18))
                    .frame(width: i == active ? 18 : 6, height: 6)
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: active)
    }
}

// MARK: - Step 1: Welcome

private struct WelcomeStep: View {
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            appIcon
                .padding(.bottom, 20)

            Text("Welcome to FastTab")
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .padding(.bottom, 10)

            Text("Search and switch browser tabs\nfrom anywhere — just hover to open.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .padding(.horizontal, 40)
                .padding(.bottom, 28)

            featureList
                .padding(.horizontal, 40)
                .padding(.bottom, 36)

            Button(action: onContinue) {
                Text("Get Started")
                    .font(.headline)
                    .frame(width: 160)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Spacer()
        }
    }

    private var appIcon: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .frame(width: 72, height: 72)
            .accessibilityHidden(true)
    }

    private var featureList: some View {
        VStack(alignment: .leading, spacing: 10) {
            FeatureRow(icon: "arrow.left.arrow.right", label: "Switch tabs instantly")
            FeatureRow(icon: "magnifyingglass", label: "Search tabs, bookmarks & history")
            FeatureRow(icon: "macwindow.on.rectangle", label: "Chrome, Edge, Brave, Safari & Finder")
            FeatureRow(icon: "square.stack", label: "Keep a Stack of tabs, synced with your iPhone")
            FeatureRow(icon: "lock.shield", label: "100% local. No data collection. No analytics.")
        }
    }
}

private struct FeatureRow: View {
    let icon: String
    let label: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 16)

            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)

            Spacer()
        }
    }
}

// MARK: - Step 2: Trigger style (headline gesture)

private struct TriggerStyleStep: View {
    @ObservedObject private var edgeReveal = EdgeRevealStore.shared
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 16)

            Image(systemName: "hand.point.up.left")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.secondary)
                .padding(.bottom, 14)

            Text("Open FastTab by Hovering")
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .padding(.bottom, 6)

            Text("Hover the spot below to open FastTab instantly. Pick where it lives:")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .padding(.horizontal, 32)
                .padding(.bottom, 18)

            previewPill
                .frame(height: 64)
                .padding(.bottom, 20)

            VStack(spacing: 8) {
                ForEach(EdgeRevealStyle.allCases) { style in
                    TriggerStyleRow(
                        style: style,
                        isSelected: edgeReveal.style == style,
                        onSelect: { edgeReveal.update(style) }
                    )
                }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 18)

            Button(action: onContinue) {
                Text("Continue")
                    .font(.headline)
                    .frame(width: 160)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Spacer(minLength: 16)
        }
    }

    /// Illustrates where the trigger sits and what shape it hugs — hovering
    /// this spot for real opens the command bar immediately, with no
    /// intermediate pill like the one shown here.
    @ViewBuilder
    private var previewPill: some View {
        if edgeReveal.style == .off {
            Text("Hover trigger off — you can set a keyboard shortcut later in this setup.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        } else {
            EdgeRevealPeekView(style: edgeReveal.style)
        }
    }
}

private struct TriggerStyleRow: View {
    let style: EdgeRevealStyle
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)

            Text(style.displayName)
                .font(.callout.weight(.medium))

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.thinMaterial)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }
}

// MARK: - Step 3: Source picker

private struct SourcePickerStep: View {
    @ObservedObject var store: SourceSelectionStore
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 20)

            Image(systemName: "square.grid.2x2")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(.secondary)
                .padding(.bottom, 14)

            Text("Where should FastTab search?")
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .padding(.bottom, 6)

            Text("Pick the apps you use. Disabled sources are skipped entirely — no background polling, no permission prompts.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .padding(.horizontal, 32)
                .padding(.bottom, 20)

            VStack(spacing: 8) {
                ForEach(SearchSource.allCases) { source in
                    SourceRow(
                        source: source,
                        isOn: Binding(
                            get: { store.isEnabled(source) },
                            set: { store.setEnabled(source, $0) }
                        )
                    )
                }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 18)

            Button(action: onContinue) {
                Text("Continue")
                    .font(.headline)
                    .frame(width: 160)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(store.enabled.isEmpty)

            if store.enabled.isEmpty {
                Text("Select at least one source to continue.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 8)
            }

            Spacer(minLength: 16)
        }
    }
}

private struct SourceRow: View {
    let source: SearchSource
    @Binding var isOn: Bool

    private var isInstalled: Bool { source.isInstalled }

    var body: some View {
        HStack(spacing: 12) {
            sourceIcon

            VStack(alignment: .leading, spacing: 1) {
                Text(source.displayName)
                    .font(.callout.weight(.medium))
                if !isInstalled {
                    Text("Not installed")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(!isInstalled)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.thinMaterial)
        )
        .opacity(isInstalled ? 1.0 : 0.55)
        .contentShape(Rectangle())
        .onTapGesture {
            guard isInstalled else { return }
            isOn.toggle()
        }
    }

    @ViewBuilder
    private var sourceIcon: some View {
        if let nsImage = appIconImage {
            Image(nsImage: nsImage)
                .resizable()
                .frame(width: 28, height: 28)
        } else {
            Image(systemName: source.symbolName)
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
        }
    }

    /// Resolves the bundled app icon for the source. Called once per row mount
    /// during onboarding only — not on a hot path, so no caching needed.
    private var appIconImage: NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: source.bundleIdentifier) else {
            return nil
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}

// MARK: - Recommended: browser extension

private struct ExtensionInstallStep: View {
    @ObservedObject private var permissions = AutomationPermissionStore.shared
    @Binding var didAutoAdvance: Bool
    let onContinue: () -> Void
    /// Advances only if this step is still showing when the delay fires.
    let onAutoAdvance: () -> Void

    private var isExtensionUsable: Bool { !permissions.usableExtensionAppNames.isEmpty }
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 12)

            Image(systemName: "puzzlepiece.extension.fill")
                .font(.system(size: 30, weight: .regular))
                .foregroundStyle(Color.accentColor)
                .padding(.bottom, 10)
                .accessibilityHidden(true)

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
    }

    /// Already set up (e.g. replaying onboarding): confirm instead of selling.
    private var subtitle: String {
        isExtensionUsable
            ? "The FastTab extension is set up — here's what it adds."
            : "Add the free FastTab extension to Chrome, Edge or Brave. FastTab works without it — this makes it better."
    }

    /// Advances itself the moment the bridge handshakes — install the
    /// extension in Chrome and this step finishes on its own.
    private func scheduleAutoAdvanceIfConnected() {
        guard !didAutoAdvance, isExtensionUsable else { return }
        didAutoAdvance = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
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

private struct SafariPermissionStep: View {
    @EnvironmentObject var appState: AppState
    @AppStorage(SafariBackend.includeFDADataDefaultsKey) private var includeSafariFDAData: Bool = SafariBackend.includeFDADataDefaultValue
    let onContinue: () -> Void

    @State private var fdaInitiallyGranted: Bool = false
    @State private var fdaGrantedNow: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 12)

            Image(systemName: "lock.shield")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(.secondary)
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
            fdaInitiallyGranted = appState.browserService.canReadSafariProtectedData()
            fdaGrantedNow = fdaInitiallyGranted
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            fdaGrantedNow = appState.browserService.canReadSafariProtectedData()
        }
    }

    private func finish(continued: Bool) {
        let granted = continued && appState.browserService.canReadSafariProtectedData()
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

private struct ShortcutStep: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var shortcutStore = ShortcutStore.shared
    @ObservedObject private var edgeReveal = EdgeRevealStore.shared
    @ObservedObject private var permissions = AutomationPermissionStore.shared
    let onDismiss: (Bool) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 12)

            Image(systemName: "keyboard")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.secondary)
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

            if OnboardingWindowController.shared.isRestartNeededToApplyChoices {
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
