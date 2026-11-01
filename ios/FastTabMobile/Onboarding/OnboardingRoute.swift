import Foundation

/// One screen of the first-run guide.
enum OnboardingStep: String, CaseIterable, Identifiable {
    /// "Do you use FastTab on your Mac?" — picks the `AppMode` and the path after it.
    case fork
    case welcome
    case connectMac
    case tryReader
    case sendToMac
    /// Reader-only path: put FastTab in the share sheet to save a first link.
    case saveFirstLink
    case done

    var id: String { rawValue }
}

/// Which screens a presentation walks through, and where the user is in them.
///
/// The full guide opens on the fork; the answer appends that mode's path
/// (`path(for:)`), and Back from its first screen returns to the fork.
/// Empty-state shortcuts ("Connect your Mac", "Add FastTab to share sheet")
/// open a single step as a sheet, which then finishes instead of moving on.
/// Pure value type so routing is unit-tested.
struct OnboardingRoute: Equatable {
    private(set) var steps: [OnboardingStep]
    private(set) var index: Int = 0
    /// A one-screen sheet has no dots, Back or Skip: it is a shortcut, not a tour.
    let isSingleStep: Bool

    static let fullGuide = OnboardingRoute(steps: [.fork], isSingleStep: false)

    static func single(_ step: OnboardingStep) -> OnboardingRoute {
        OnboardingRoute(steps: [step], isSingleStep: true)
    }

    /// The screens after the fork for each answer.
    static func path(for mode: AppMode) -> [OnboardingStep] {
        switch mode {
        case .mac: return [.welcome, .connectMac, .tryReader, .sendToMac, .done]
        case .standalone: return [.saveFirstLink, .tryReader, .done]
        }
    }

    var current: OnboardingStep { steps[index] }
    var isFirst: Bool { index == 0 }
    var isLast: Bool { index == steps.count - 1 }

    /// The path picked at the fork, if any.
    var chosenMode: AppMode? {
        AppMode.allCases.first { steps.dropFirst() == Self.path(for: $0)[...] }
    }

    /// Answers the fork (or switches path mid-guide, e.g. "Continue without a Mac")
    /// and moves to that path's first screen.
    mutating func choose(_ mode: AppMode) {
        steps = [.fork] + Self.path(for: mode)
        index = 1
    }

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
