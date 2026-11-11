import Foundation
import CommandBarKit

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
    /// `orderedViews` is the swipe order (`CommandBarViewStore.availableViews`);
    /// a leftward flick (negative delta) moves one page forward, rightward
    /// one page back, clamped at both ends.
    mutating func handleScroll(
        deltaX: CGFloat,
        deltaY: CGFloat = 0,
        isEnded: Bool,
        isMomentum: Bool = false,
        currentView: CommandBarView,
        orderedViews: [CommandBarView] = CommandBarView.builtins
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
        let step = deltaX < 0 ? 1 : -1
        guard let target = CommandBarView.neighbor(of: currentView, step: step, in: orderedViews) else {
            accumulator = 0
            return nil
        }

        accumulator += deltaX

        if abs(accumulator) >= Self.threshold {
            isSuppressed = true
            accumulator = 0
            return target
        }

        return nil
    }
}
