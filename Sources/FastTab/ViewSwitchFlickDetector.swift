import Foundation

struct ViewSwitchFlickDetector {
    static let threshold: CGFloat = 60.0

    private(set) var accumulator: CGFloat = 0
    private(set) var isSuppressed: Bool = false

    mutating func reset() {
        accumulator = 0
        isSuppressed = false
    }

    /// Processes horizontal scroll delta with vertical scroll safety.
    /// Returns the target view to switch to if a flick triggered, or nil.
    mutating func handleScroll(
        deltaX: CGFloat,
        deltaY: CGFloat = 0,
        isEnded: Bool,
        isMomentum: Bool = false,
        currentView: CommandBarView
    ) -> CommandBarView? {
        if isEnded {
            accumulator = 0
            isSuppressed = false
            return nil
        }

        guard !isSuppressed, !isMomentum else { return nil }

        // If the scroll is predominantly vertical, reset horizontal accumulation
        // so vertical list scrolling never triggers an accidental view switch.
        let absX = abs(deltaX)
        let absY = abs(deltaY)
        if absY > absX {
            accumulator = 0
            return nil
        }

        // Filter sub-pixel jitter
        guard absX >= 1.5 else { return nil }

        // Direction clamping: cannot flick further than edges
        if currentView == .stack && deltaX < 0 {
            accumulator = 0
            return nil
        }
        if currentView == .recents && deltaX > 0 {
            accumulator = 0
            return nil
        }

        accumulator += deltaX

        if accumulator <= -Self.threshold {
            isSuppressed = true
            accumulator = 0
            switch currentView {
            case .recents: return .stack
            case .stack: return nil
            }
        } else if accumulator >= Self.threshold {
            isSuppressed = true
            accumulator = 0
            switch currentView {
            case .stack: return .recents
            case .recents: return nil
            }
        }

        return nil
    }
}
