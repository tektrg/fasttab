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

        win.setContentSize(NSSize(width: 440, height: 460))
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

// MARK: - Root View

struct OnboardingView: View {
    @EnvironmentObject var appState: AppState
    let onDismiss: (Bool) -> Void

    @State private var step = 0

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.ultraThinMaterial)

            VStack(spacing: 0) {
                Group {
                    if step == 0 {
                        WelcomeStep {
                            withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                                step = 1
                            }
                        }
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .offset(x: 32)),
                            removal: .opacity.combined(with: .offset(x: -32))
                        ))
                    } else {
                        ShortcutStep(onDismiss: onDismiss)
                            .transition(.asymmetric(
                                insertion: .opacity.combined(with: .offset(x: 32)),
                                removal: .opacity.combined(with: .offset(x: -32))
                            ))
                    }
                }
                .animation(.spring(response: 0.38, dampingFraction: 0.82), value: step)

                stepDots
                    .padding(.bottom, 20)
            }
        }
        .frame(width: 440, height: 460)
    }

    private var stepDots: some View {
        HStack(spacing: 6) {
            ForEach(0..<2) { i in
                Capsule()
                    .fill(i == step ? Color.primary.opacity(0.7) : Color.primary.opacity(0.18))
                    .frame(width: i == step ? 18 : 6, height: 6)
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: step)
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
            FeatureRow(icon: "macwindow.on.rectangle", label: "Works across Chrome and Edge")
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

// MARK: - Step 2: Shortcut

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

            Text("The first time you search, macOS will ask to allow FastTab to control Chrome or Edge. Click **Allow** to enable tab switching.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.leading)
        }
    }
}
