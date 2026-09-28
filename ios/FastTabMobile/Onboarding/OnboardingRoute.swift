import Foundation

/// One screen of the first-run guide.
enum OnboardingStep: String, CaseIterable, Identifiable {
    case welcome
    case connectMac
    case tryReader
    case sendToMac
    case done

    var id: String { rawValue }
}

/// Which screens a presentation walks through, and where the user is in them.
///
/// The full guide runs every step. Empty-state shortcuts ("Connect your Mac",
/// "Add FastTab to share sheet") open a single step as a sheet, which then
/// finishes instead of moving on. Pure value type so routing is unit-tested.
struct OnboardingRoute: Equatable {
    let steps: [OnboardingStep]
    private(set) var index: Int = 0

    static let fullGuide = OnboardingRoute(steps: OnboardingStep.allCases)

    static func single(_ step: OnboardingStep) -> OnboardingRoute {
        OnboardingRoute(steps: [step])
    }

    var current: OnboardingStep { steps[index] }
    var isFirst: Bool { index == 0 }
    var isLast: Bool { index == steps.count - 1 }
    /// A one-screen sheet has no dots, Back or Skip: it is a shortcut, not a tour.
    var isSingleStep: Bool { steps.count == 1 }

    /// Moves forward. Returns `false` when there is nowhere to go and the
    /// presentation should finish instead.
    mutating func advance() -> Bool {
        guard !isLast else { return false }
        index += 1
        return true
    }

    mutating func goBack() {
        guard !isFirst else { return }
        index -= 1
    }
}
