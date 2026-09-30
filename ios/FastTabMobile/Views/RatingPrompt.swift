import SwiftUI
import StoreKit
import IndieMotion

/// When and how FastTab asks for a rating. The timing is IndieMotion's
/// `MotionRatingPolicy.standard`; the state is a `MotionRatingState` stored as text
/// under `ratingPromptState`.
///
/// Meaningful success: opening a result from Tabs search (tab, bookmark or history
/// row) and coming back from the browser. The popup shows at that calm moment,
/// a beat after the browser closes. "Rate" calls StoreKit's `requestReview` once
/// our sheet has fully dismissed (the OS drops it over a sheet still animating away).
@MainActor
final class RatingPromptCoordinator: ObservableObject {
    static let shared = RatingPromptCoordinator()
    static let defaultsKey = "ratingPromptState"
    /// DEBUG: `-FastTabForceRatingPrompt YES` shows the popup at launch.
    static let forceLaunchArgument = "FastTabForceRatingPrompt"

    @Published var isPresented = false
    /// Set by "Rate"; the presenter requests the review once the sheet is gone.
    private(set) var wantsReviewAfterDismiss = false
    /// A debug force-show: shown, but never written to the real ask state.
    private var isForced = false
    private let defaults = UserDefaults.standard

    private var state: MotionRatingState {
        get { defaults.string(forKey: Self.defaultsKey).flatMap(MotionRatingState.init(rawValue:)) ?? MotionRatingState() }
        set { defaults.set(newValue.rawValue, forKey: Self.defaultsKey) }
    }

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    private var isFair: Bool { MotionRatingPolicy.standard.shouldAsk(state, now: Date(), version: version) }

    private init() {
        state = state.noting(launchAt: Date())
        #if DEBUG
        if defaults.bool(forKey: Self.forceLaunchArgument) { forceShow() }
        #endif
    }

    /// A search result was opened and the person is back: count it, then ask if fair.
    func searchResultVisitEnded() {
        state = state.recordingSuccess(at: Date())
        guard isFair else { return }
        Task {
            try? await Task.sleep(for: .seconds(0.8))  // let the browser finish closing
            // Only record an ask the person will actually see.
            guard !isPresented, isFair, !Self.isSomethingPresented else { return }
            state = state.asking(at: Date(), version: version)
            isForced = false
            isPresented = true
        }
    }

    /// Debug: show the popup without touching the stored ask state.
    func forceShow() {
        isForced = true
        isPresented = true
    }

    func finish(_ answer: MotionRatingAnswer) {
        if !isForced { state = state.answering(answer) }
        wantsReviewAfterDismiss = answer == .requestedReview
        isPresented = false
    }

    /// The sheet finished dismissing: true once if "Rate" was tapped.
    func takeReviewRequest() -> Bool {
        defer { wantsReviewAfterDismiss = false }
        return wantsReviewAfterDismiss
    }

    /// Another sheet, alert or the browser is still up (would hide or block ours).
    private static var isSomethingPresented: Bool {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow?.rootViewController }
            .contains { $0.presentedViewController != nil }
    }
}

/// Presents the rating popup as a sheet from the app root.
struct RatingPromptPresenter: ViewModifier {
    @ObservedObject private var coordinator = RatingPromptCoordinator.shared
    @Environment(\.requestReview) private var requestReview
    /// At accessibility text sizes the half-height sheet hides the answer buttons
    /// below the stars, so open it full height.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    func body(content: Content) -> some View {
        content.sheet(isPresented: Binding(
            get: { coordinator.isPresented },
            set: { if !$0 && coordinator.isPresented { coordinator.finish(.declined) } }
        ), onDismiss: {
            if coordinator.takeReviewRequest() { requestReview() }
        }) {
            RatingPromptSheet { coordinator.finish($0) }
                .presentationDetents(dynamicTypeSize.isAccessibilitySize ? [.large] : [.medium, .large])
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

    static let text = MotionRatingPromptText(
        title: String(localized: "Enjoying FastTab?"),
        message: String(localized: "Would you leave a quick rating? It really helps other people find FastTab."),
        rate: String(localized: "Rate"),
        notNow: String(localized: "Not now"),
        close: String(localized: "Close")
    )

    var body: some View {
        ScrollView {
            MotionRatingPrompt(text: Self.text, onFinish: onFinish)
                .padding(.vertical, DS.Space.xl)
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}
