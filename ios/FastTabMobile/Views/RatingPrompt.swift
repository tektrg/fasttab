import SwiftUI
import StoreKit
import IndieMotion

/// When and how FastTab asks for a rating. The timing is IndieMotion's
/// `MotionRatingPolicy.standard`; the state is a `MotionRatingState` stored as text
/// under `ratingPromptState`.
///
/// Meaningful success: opening a result from Tabs search (tab, bookmark or history
/// row) and coming back from the browser. The popup shows at that calm moment,
/// a beat after the browser closes. No App Store app id and no feedback channel
/// exist yet, so "Rate" calls StoreKit's `requestReview` and "Not really" just
/// thanks the person.
@MainActor
final class RatingPromptCoordinator: ObservableObject {
    static let shared = RatingPromptCoordinator()
    static let defaultsKey = "ratingPromptState"
    /// DEBUG: `-FastTabForceRatingPrompt YES` shows the popup at launch.
    static let forceLaunchArgument = "FastTabForceRatingPrompt"

    @Published var isPresented = false
    private let defaults = UserDefaults.standard

    private var state: MotionRatingState {
        get { defaults.string(forKey: Self.defaultsKey).flatMap(MotionRatingState.init(rawValue:)) ?? MotionRatingState() }
        set { defaults.set(newValue.rawValue, forKey: Self.defaultsKey) }
    }

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    private init() {
        state = state.noting(launchAt: Date())
        #if DEBUG
        if defaults.bool(forKey: Self.forceLaunchArgument) { forceShow() }
        #endif
    }

    /// A search result was opened and the person is back: count it, then ask if fair.
    func searchResultVisitEnded() {
        let now = Date()
        state = state.recordingSuccess(at: now)
        guard MotionRatingPolicy.standard.shouldAsk(state, now: now, version: version) else { return }
        Task {
            try? await Task.sleep(for: .seconds(0.8))  // let the browser finish closing
            present()
        }
    }

    func forceShow() { present() }

    private func present() {
        state = state.asking(at: Date(), version: version)
        isPresented = true
    }

    func finish(_ answer: MotionRatingAnswer) {
        state = state.answering(answer)
        isPresented = false
    }
}

/// Presents the rating popup as a sheet from the app root.
struct RatingPromptPresenter: ViewModifier {
    @ObservedObject private var coordinator = RatingPromptCoordinator.shared

    func body(content: Content) -> some View {
        content.sheet(isPresented: Binding(
            get: { coordinator.isPresented },
            set: { if !$0 && coordinator.isPresented { coordinator.finish(.declined) } }
        )) {
            RatingPromptSheet { coordinator.finish($0) }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }
}

extension View {
    func ratingPrompt() -> some View { modifier(RatingPromptPresenter()) }
}

/// The popup's content with FastTab's wording.
struct RatingPromptSheet: View {
    let onFinish: (MotionRatingAnswer) -> Void
    @Environment(\.requestReview) private var requestReview

    static let text = MotionRatingPromptText(
        askTitle: String(localized: "Enjoying FastTab?"),
        askMessage: String(localized: "A quick yes or no helps us know what's working."),
        yes: String(localized: "Yes!"),
        no: String(localized: "Not really"),
        rateTitle: String(localized: "Yay, glad to hear it!"),
        rateMessage: String(localized: "Would you leave a quick rating? It really helps other people find FastTab."),
        rate: String(localized: "Rate"),
        notNow: String(localized: "Not now"),
        feedbackTitle: String(localized: "Thanks for telling us"),
        feedbackMessage: String(localized: "We'll keep making FastTab better. We won't ask again for a while."),
        sendFeedback: String(localized: "Send feedback"),
        close: String(localized: "Close"),
        starsLabel: String(localized: "Rating")
    )

    var body: some View {
        ScrollView {
            MotionRatingPrompt(text: Self.text, onRate: { requestReview() }, onFinish: onFinish)
                .padding(.vertical, DS.Space.xl)
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}
