import SwiftUI

/// What the guide is showing right now, if anything.
enum OnboardingPresentation: Identifiable, Equatable {
    /// The whole first-run guide, full screen.
    case fullGuide
    /// One step as a sheet, opened from an empty state or the sync banner.
    case singleStep(OnboardingStep)

    var id: String {
        switch self {
        case .fullGuide: return "fullGuide"
        case .singleStep(let step): return "step-\(step.rawValue)"
        }
    }

    var route: OnboardingRoute {
        switch self {
        case .fullGuide: return .fullGuide
        case .singleStep(let step): return .single(step)
        }
    }
}

/// App-wide switch for opening the guide, so any empty state can offer
/// "Connect your Mac" without threading bindings through every screen.
/// `FastTabMobileApp` owns the actual `fullScreenCover` / `sheet`.
@MainActor
final class OnboardingPresenter: ObservableObject {
    static let shared = OnboardingPresenter()

    @Published var fullScreen: OnboardingPresentation?
    @Published var sheet: OnboardingPresentation?

    func present(_ presentation: OnboardingPresentation) {
        switch presentation {
        case .fullGuide: fullScreen = presentation
        case .singleStep: sheet = presentation
        }
    }
}
