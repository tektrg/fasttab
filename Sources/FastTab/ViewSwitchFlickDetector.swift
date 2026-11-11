import Foundation
import IndieCommandBar

/// Fast Tab's view flick: the shared `CommandBarViewFlick` over
/// `CommandBarView` pages.
struct ViewSwitchFlickDetector {
    static let threshold: CGFloat = CommandBarViewFlick.threshold

    private var flick = CommandBarViewFlick()

    var accumulator: CGFloat { flick.accumulator }
    var isSuppressed: Bool { flick.isSuppressed }

    mutating func reset() { flick.reset() }

    /// `orderedViews` is the swipe order (`CommandBarViewStore.availableViews`);
    /// a leftward flick moves one page forward, rightward one back, clamped.
    mutating func handleScroll(
        deltaX: CGFloat,
        deltaY: CGFloat = 0,
        isEnded: Bool,
        isMomentum: Bool = false,
        currentView: CommandBarView,
        orderedViews: [CommandBarView] = CommandBarView.builtins
    ) -> CommandBarView? {
        flick.handleScroll(
            deltaX: deltaX, deltaY: deltaY, isEnded: isEnded, isMomentum: isMomentum,
            current: currentView, ordered: orderedViews
        )
    }

    mutating func handleEvent(
        deltaX: CGFloat, deltaY: CGFloat, began: Bool, touchEnded: Bool, momentumEnded: Bool,
        cancelled: Bool, isMomentum: Bool, currentView: CommandBarView, orderedViews: [CommandBarView]
    ) -> (target: CommandBarView?, consumed: Bool) {
        flick.handleEvent(
            deltaX: deltaX, deltaY: deltaY, began: began, touchEnded: touchEnded,
            momentumEnded: momentumEnded, cancelled: cancelled, isMomentum: isMomentum,
            current: currentView, ordered: orderedViews
        )
    }
}
