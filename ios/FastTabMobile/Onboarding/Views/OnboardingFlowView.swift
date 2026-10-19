import SwiftUI
import IndieMotion

/// How the guide was left, so the app can decide where to land.
enum OnboardingExit {
    /// "Skip" on any screen of the full guide.
    case skipped
    /// "Start reading" on the last screen.
    case finished
    /// "Done" on a one-screen sheet.
    case closed
}

/// Hosts the guide: Back / Skip on top, the current screen, page dots below.
/// A one-screen sheet (from an empty state) shows the screen alone.
struct OnboardingFlowView: View {
    @State private var route: OnboardingRoute
    let onExit: (OnboardingExit) -> Void
    @ObservedObject private var localCache = LocalCache.shared

    init(route: OnboardingRoute, onExit: @escaping (OnboardingExit) -> Void) {
        _route = State(initialValue: route)
        self.onExit = onExit
    }

    var body: some View {
        VStack(spacing: 0) {
            if !route.isSingleStep && route.current != .fork {
                navigationBar
            }

            currentStep
                .id(route.current)
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .opacity
                ))
                .frame(maxHeight: .infinity)
                // Scrolled text stops at the Back / Skip bar instead of sliding under it.
                .clipped()

            if !route.isSingleStep && route.current != .fork {
                OnboardingPageDots(count: route.steps.count, currentIndex: route.index)
                    .padding(.bottom, DS.Space.md)
            }
        }
        .dsCanvas()
        // Let the first screen paint before creating the warm web view / reading the sample.
        .task {
            try? await Task.sleep(for: .milliseconds(600))
            if !Task.isCancelled { preloadTryoutArticle() }
        }
        .onChange(of: localCache.state.tabs) { _, _ in preloadTryoutArticle() }
        .onChange(of: route.chosenMode) { _, _ in preloadTryoutArticle() }
        .onDisappear { ReaderPreloader.shared.cancel() }
    }

    /// Gets the "Try Reader" article ready while the user is still on earlier screens: the
    /// Mac's article once tabs sync in, else the bundled sample. Later syncs can re-run this.
    private func preloadTryoutArticle() {
        guard route.steps.contains(.tryReader), route.current != .tryReader else { return }
        if !usesSampleOnly,
           let tab = ReaderTryoutPicker.pick(from: localCache.state.tabs),
           let url = URL(string: tab.url) {
            ReaderPreloader.shared.preload(url: url)
        } else {
            ReaderPreloader.shared.preloadSample()
        }
    }

    private var navigationBar: some View {
        HStack {
            if !route.isFirst {
                Button {
                    withAnimation(.easeInOut(duration: 0.25)) { route.goBack() }
                    announceScreenChange()
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .buttonStyle(OnboardingBarButtonStyle())
            }
            Spacer()
            if !route.isLast {
                Button("Skip") { onExit(.skipped) }
                    .buttonStyle(OnboardingBarButtonStyle())
            }
        }
        .font(DS.Font.body.weight(.medium))
        .frame(minHeight: 44)
        .padding(.horizontal, DS.Space.gutter)
        .padding(.vertical, DS.Space.xs)
    }

    /// Reader-only users have no Mac tabs: the Reader demo opens the bundled sample.
    private var usesSampleOnly: Bool {
        route.chosenMode == .standalone
    }

    @ViewBuilder
    private var currentStep: some View {
        switch route.current {
        case .fork:
            OnboardingForkStep(onChoose: choose)
        case .saveFirstLink:
            OnboardingSaveFirstLinkStep(isSingleStep: route.isSingleStep, onContinue: advance)
        case .welcome:
            OnboardingWelcomeStep(onContinue: advance)
        case .connectMac:
            OnboardingConnectMacStep(
                isStandalone: route.isSingleStep,
                onContinue: advance,
                // Switches to the reader-only path (and mode); Back still reaches the fork.
                onContinueWithoutMac: { choose(.standalone) }
            )
        case .tryReader:
            OnboardingTryReaderStep(useSampleOnly: usesSampleOnly, isStandalone: route.isSingleStep, onContinue: advance)
        case .sendToMac:
            OnboardingSendToMacStep(isStandalone: route.isSingleStep, onContinue: advance)
        case .done:
            OnboardingDoneStep(onStart: advance)
        }
    }

    /// Records the answer as the app's mode right away, so the share extension and
    /// root tabs follow it even if the user skips the rest of the guide.
    private func choose(_ mode: AppMode) {
        AppModeModel.shared.set(mode)
        var next = route
        next.choose(mode)
        withAnimation(.easeInOut(duration: 0.25)) { route = next }
        announceScreenChange()
    }

    private func advance() {
        var next = route
        guard next.advance() else {
            onExit(route.isSingleStep ? .closed : .finished)
            return
        }
        withAnimation(.easeInOut(duration: 0.25)) { route = next }
        announceScreenChange()
    }

    /// Moves VoiceOver to the new screen instead of leaving it on the old button.
    private func announceScreenChange() {
        UIAccessibility.post(notification: .screenChanged, argument: nil)
    }
}

/// Back / Skip: a soft pastel lavender capsule (house chibi style), so the
/// buttons read as buttons at any text size.
private struct OnboardingBarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        let swatch = HeroInk.palette.lavender
        configuration.label
            .foregroundStyle(swatch.ink)
            .padding(.horizontal, DS.Space.md)
            .padding(.vertical, DS.Space.xs + 2)
            .background(swatch.fill.opacity(0.45), in: Capsule())
            .opacity(configuration.isPressed ? 0.6 : 1)
            .contentShape(Capsule())
    }
}
