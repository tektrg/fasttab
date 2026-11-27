import SwiftUI
import AppKit
import IndieOnboarding
import IndieCommandBar
import IndieEdgeReveal

/// The onboarding window's size: the shared `OnboardingWizardLayout` (IndieOnboarding), which
/// picks `compact` on a short screen. Every step must fit both (pinned by `OnboardingStepFitTests`).
typealias OnboardingLayout = OnboardingWizardLayout

// MARK: - Coordinator

/// Fast Tab's onboarding window. The window, the step chrome and the "has onboarded" flag are the
/// shared wizard (IndieOnboarding); what is left here is what only Fast Tab knows — which choices
/// need a fresh process, and what to do once the wizard closes.
@MainActor
final class OnboardingWindowController: NSObject {
    static let shared = OnboardingWindowController()
    /// Shared by the menu bar item and Settings > About.
    static let replayMenuTitle = "Replay Onboarding…"

    /// Full Disk Access state when this process started (the controller is first touched at
    /// launch). Safari's protected data only becomes readable after a relaunch, so a grant during
    /// onboarding needs one.
    private let safariDataReadableAtLaunch = AppState.shared.browserService.canReadSafariProtectedData()

    private lazy var wizard = OnboardingWizardWindowController(
        completion: FastTabOnboarding.completion()
    ) { [weak self] layout, dismiss in
        AnyView(
            OnboardingView(layout: layout) { shouldOpenBar in
                self?.finish(andOpenBar: shouldOpenBar, dismiss: dismiss)
            }
            .environmentObject(AppState.shared)
        )
    }

    var isNeeded: Bool { wizard.isNeeded }

    /// Onboarding choices that only take effect in a fresh process: source toggles (backends are
    /// built once at launch — see `BrowserTabService.init`) and a Full Disk Access grant for Safari
    /// bookmarks/history.
    var isRestartNeededToApplyChoices: Bool {
        let sources = SourceSelectionStore.shared
        if sources.needsRestartToApply { return true }
        guard sources.isEnabled(.safari), SafariBackend.isFDADataIncluded(), !safariDataReadableAtLaunch else { return false }
        return AppState.shared.browserService.canReadSafariProtectedData()
    }

    /// Opens onboarding from the first step. Also used to replay it later (menu bar / Settings);
    /// replaying only re-shows the steps — existing settings are kept and pre-filled.
    func show() {
        wizard.show()
    }

    private func finish(andOpenBar: Bool, dismiss: () -> Void) {
        let needsRestart = isRestartNeededToApplyChoices
        dismiss()
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
enum OnboardingStep: Hashable {
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

    /// Lifted out of `ExtensionInstallStep` so stepping Back onto it doesn't
    /// auto-advance the user forward again.
    @State private var didAutoAdvancePastExtension = false

    /// Conditional steps, so the wizard's dots follow a live list: unticking Safari on the picker
    /// step drops its permission step while the wizard is open.
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

    var body: some View {
        OnboardingWizardView(steps: steps, layout: layout) { step, actions in
            stepView(step, actions)
        }
    }

    @ViewBuilder
    private func stepView(_ step: OnboardingStep, _ actions: OnboardingWizardActions<OnboardingStep>) -> some View {
        switch step {
        case .welcome:
            WelcomeStep(onContinue: actions.advance)
        case .triggerStyle:
            TriggerStyleStep(onContinue: actions.advance)
        case .sources:
            SourcePickerStep(store: selectionStore, onContinue: actions.advance)
        case .extensionInstall:
            ExtensionInstallStep(
                didAutoAdvance: $didAutoAdvancePastExtension,
                onContinue: actions.advance,
                onAutoAdvance: { actions.advanceIfStillOn(.extensionInstall) }
            )
        case .safariPermission:
            SafariPermissionStep(onContinue: actions.advance)
        case .iPhoneApp:
            OnboardingIPhoneStep(onContinue: actions.advance)
        case .shortcut:
            ShortcutStep(onDismiss: onDismiss)
        }
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
                ForEach(EdgeRevealStyle.onboardingChoices) { style in
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
            Spacer(minLength: 12)

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

            Group {
                if SearchSource.allCases.count > 5 {
                    ScrollView {
                        sourceRows
                    }
                    .frame(maxHeight: 240)
                } else {
                    sourceRows
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

            Spacer(minLength: 12)
        }
    }

    private var sourceRows: some View {
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
