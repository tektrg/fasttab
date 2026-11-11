import CoreGraphics

/// Turns a horizontal two-finger swipe into one page step (same feel as Fast Tab's view
/// switching): a predominantly horizontal scroll past `threshold` points fires once per gesture.
/// Leftward (negative delta) = next page. Vertical scrolling never counts. Pure.
struct AgentPageFlickDetector {
    static let threshold: CGFloat = 60

    private(set) var accumulator: CGFloat = 0
    private(set) var isSuppressed = false

    /// The step to take (+1 / -1) when this event completes a flick, else nil.
    mutating func handleScroll(deltaX: CGFloat, deltaY: CGFloat, isEnded: Bool, isMomentum: Bool) -> Int? {
        if isEnded {
            accumulator = 0
            isSuppressed = false
            return nil
        }
        guard !isSuppressed, !isMomentum else { return nil }
        guard abs(deltaX) > abs(deltaY) else {
            accumulator = 0
            return nil
        }
        guard abs(deltaX) >= 1.5 else { return nil }
        accumulator += deltaX
        guard abs(accumulator) >= Self.threshold else { return nil }
        isSuppressed = true
        let step = accumulator < 0 ? 1 : -1
        accumulator = 0
        return step
    }
}
