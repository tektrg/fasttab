import SwiftUI
import AppKit

private let onboardingCompletedKey = "onboarding.v1.completed"

// MARK: - Coordinator

@MainActor
final class OnboardingWindowController: NSObject {
    static let shared = OnboardingWindowController()

    private var window: NSWindow?

    var isNeeded: Bool {
        !UserDefaults.standard.bool(forKey: onboardingCompletedKey)
    }

    func show() {
        guard window == nil else { return }

        let view = OnboardingView { [weak self] shouldOpenBar in
            self?.dismiss(andOpenBar: shouldOpenBar)
        }
        .environmentObject(AppState.shared)

        let controller = NSHostingController(rootView: view)
        controller.view.wantsLayer = true

        let win = NSWindow(contentViewController: controller)
        win.styleMask = [.titled, .fullSizeContentView]
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = true
        win.isMovableByWindowBackground = true

        [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].forEach {
            win.standardWindowButton($0)?.isHidden = true
        }

        win.setContentSize(NSSize(width: 440, height: 520))
        win.center()
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        window = win
    }

    private func dismiss(andOpenBar: Bool) {
        window?.close()
        window = nil
        UserDefaults.standard.set(true, forKey: onboardingCompletedKey)
        if andOpenBar {
            AppState.shared.showCommandBar()
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
    case sources
    case safariPermission
    case shortcut
}

// MARK: - Root View

struct OnboardingView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var selectionStore = SourceSelectionStore.shared
    let onDismiss: (Bool) -> Void

    @State private var stepIndex: Int = 0

    private var steps: [OnboardingStep] {
        var list: [OnboardingStep] = [.welcome, .sources]
        if selectionStore.enabled.contains(.safari) {
            list.append(.safariPermission)
        }
        list.append(.shortcut)
        return list
    }

    /// Current step, clamped to the live `steps` list. The list shrinks when
    /// the user unchecks Safari on the picker step, so the index can momentarily
    /// point past the end — clamp rather than crash.
    private var currentStep: OnboardingStep {
        let safeIndex = min(max(stepIndex, 0), steps.count - 1)
        return steps[safeIndex]
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
                    case .sources:
                        SourcePickerStep(
                            store: selectionStore,
                            onContinue: advance
                        )
                        .transition(stepTransition)
                    case .safariPermission:
                        SafariPermissionStep(onContinue: advance)
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
            stepIndex = min(stepIndex + 1, count - 1)
        }
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

            Text("Search and switch between browser tabs\nfrom anywhere — one shortcut, any app.")
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
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.thinMaterial)
                .frame(width: 64, height: 64)

            Image(systemName: "command")
                .font(.system(size: 32, weight: .regular))
                .foregroundStyle(.primary)
        }
    }

    private var featureList: some View {
        VStack(alignment: .leading, spacing: 10) {
            FeatureRow(icon: "arrow.left.arrow.right", label: "Switch tabs instantly")
            FeatureRow(icon: "magnifyingglass", label: "Search tabs, bookmarks & history")
            FeatureRow(icon: "macwindow.on.rectangle", label: "Works across Chrome, Edge, Safari & Finder")
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

// MARK: - Step 2: Source picker

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

// MARK: - Step 3: Safari permission (conditional)

private struct SafariPermissionStep: View {
    @EnvironmentObject var appState: AppState
    @AppStorage("FastTab.safari.includeFDAData") private var includeSafariFDAData: Bool = true
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
                    Text("Full Disk Access granted — restart required after onboarding.")
                        .font(.caption)
                    Spacer()
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 12)
            }

            HStack(spacing: 14) {
                Button("Skip") {
                    includeSafariFDAData = false
                    onContinue()
                }
                .buttonStyle(.plain)
                .font(.callout)
                .foregroundStyle(.tertiary)

                Button {
                    includeSafariFDAData = true
                    onContinue()
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

    private func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Step 4: Shortcut

private struct ShortcutStep: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var shortcutStore = ShortcutStore.shared
    let onDismiss: (Bool) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            Image(systemName: "keyboard")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(.secondary)
                .padding(.bottom, 18)

            Text("Your Shortcut")
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .padding(.bottom, 8)

            Text("Press this from any app to open FastTab:")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.bottom, 24)

            ShortcutRecorderView(store: shortcutStore)
                .padding(.bottom, 10)

            Text("You can change this later in Settings…")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 18)

            automationNote
                .padding(.horizontal, 40)
                .padding(.bottom, 36)

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

    private var automationNote: some View {
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
