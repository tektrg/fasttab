import CoreGraphics

/// Picks Focus mode's text sizes from the room a panel has (pure, unit-tested). Base 22pt body /
/// 26pt question; steps down 1pt at a time to the floor 15 / 18; below that the panel scrolls.
/// The left (context) and right (question) panels each run this on their own.
///
/// Height is estimated from one measurement at the base size: wrapped text grows with the square
/// of the size (more lines AND taller lines at a fixed width).
struct FocusTextFit: Equatable {
    static let baseBody: CGFloat = 22
    static let baseQuestion: CGFloat = 26
    static let floorBody: CGFloat = 15
    static let floorQuestion: CGFloat = 18

    let body: CGFloat
    let question: CGFloat
    /// Even the floor does not fit: the panel scrolls.
    let scrolls: Bool

    static let base = FocusTextFit(body: baseBody, question: baseQuestion, scrolls: false)

    /// `heightAtBase`: the content's natural height drawn at the base sizes.
    static func fit(heightAtBase: CGFloat, available: CGFloat) -> FocusTextFit {
        guard heightAtBase > 0, available > 0 else { return base }
        var body = baseBody
        while body >= floorBody {
            let ratio = body / baseBody
            if heightAtBase * ratio * ratio <= available {
                return FocusTextFit(body: body, question: questionSize(forBody: body), scrolls: false)
            }
            body -= 1
        }
        return FocusTextFit(body: floorBody, question: floorQuestion, scrolls: true)
    }

    /// The question size that goes with a body size (linear between base and floor).
    static func questionSize(forBody body: CGFloat) -> CGFloat {
        let t = (body - floorBody) / (baseBody - floorBody)
        return (floorQuestion + t * (baseQuestion - floorQuestion)).rounded()
    }
}
