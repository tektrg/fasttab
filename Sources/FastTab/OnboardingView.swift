import SwiftUI
import AppKit
import CommandBarKit

private let onboardingCompletedKey = "onboarding.v1.completed"

/// The onboarding window's size. It is fixed and unmovable, so it must fit the
/// screen: short screens (13" Macs at larger-text scaling, with the Dock
/// showing) get `compact`, which draws the heroes at half size. Every step
/// must fit both (pinned by `OnboardingStepFitTests`).
struct OnboardingLayout: Equatable, Sendable {
    let windowSize: CGSize
    /// How big the animated heroes draw: 1 is the storyboard's 200 × 96 pt
    /// (`OnboardingHeroes/`).
    let heroScale: Double
    let stepDotsBottomPadding: CGFloat

    static let regular = OnboardingLayout(
        windowSize: CGSize(width: 440, height: 580), heroScale: 1, stepDotsBottomPadding: 20
    )
    static let compact = OnboardingLayout(
        windowSize: CGSize(width: 440, height: 530), heroScale: 0.5, stepDotsBottomPadding: 12
    )
    static let all = [regular, compact]

    static let stepDotSize: CGFloat = 6
    /// Room kept between the window and the screen's usable edges (menu bar, Dock).
    static let screenMargin: CGFloat = 20

    /// Height left for the current step above the step dots.
    var stepHeight: CGFloat { windowSize.height - Self.stepDotSize - stepDotsBottomPadding }

    /// `regular` when it fits the screen's usable height, else `compact`.
    static func fitting(visibleScreenHeight: CGFloat) -> OnboardingLayout {
        visibleScreenHeight >= regular.windowSize.height + screenMargin ? .regular : .compact
    }
}

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

        let layout = OnboardingLayout.fitting(visibleScreenHeight: NSScreen.main?.visibleFrame.height ?? .infinity)
        let view = OnboardingView(layout: layout) { [weak self] shouldOpenBar in
            self?.dismiss(andOpenBar: shouldOpenBar)
        }
        .environmentObject(AppState.shared)

        let controller = NSHostingController(rootView: view)
        controller.view.wantsLayer = true

        let win = NSWindow(contentViewController: controller)
        Self.configureOnboardingWindow(win, layout: layout)
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        window = win
    }

    static func configureOnboardingWindow(_ win: NSWindow, layout: OnboardingLayout) {
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

        win.setContentSize(layout.windowSize)
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
    let layout: OnboardingLayout
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
                    .padding(.bottom, layout.stepDotsBottomPadding)
            }
        }
        .overlay(alignment: .topLeading) {
            if clampedStepIndex > 0 {
                backButton
            }
        }
        .environment(\.onboardingHeroScale, layout.heroScale)
        .frame(width: layout.windowSize.width, height: layout.windowSize.height)
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
                    .frame(width: i == active ? 18 : OnboardingLayout.stepDotSize, height: OnboardingLayout.stepDotSize)
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: active)
    }
}

// MARK: - Step 1: Welcome

struct WelcomeStep: View {
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            OnboardingHeroWelcome()
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

struct TriggerStyleStep: View {
    @ObservedObject var edgeReveal: EdgeRevealStore = .shared
    @ObservedObject private var shortcutStore = ShortcutStore.shared
    let onContinue: () -> Void

    private var heroState: TriggerHeroState {
        TriggerHeroState(style: edgeReveal.style, shortcutKeycaps: shortcutStore.heroKeycaps)
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 16)

            OnboardingHeroTrigger(state: heroState)
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
            .padding(.bottom, edgeReveal.style == .off ? 8 : 18)

            if edgeReveal.style == .off {
                Text("Hover trigger off — you can set a keyboard shortcut later in this setup.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                    .padding(.bottom, 12)
            }

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

struct SourcePickerStep: View {
    @ObservedObject var store: SourceSelectionStore
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 20)

            OnboardingHeroSources(state: SourcesHeroState(enabled: store.enabled))
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
        if let nsImage = source.appIconImage {
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
}
