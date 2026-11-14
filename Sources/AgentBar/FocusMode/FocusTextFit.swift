import CoreGraphics

/// Picks Focus mode's text sizes from the room a panel has (pure, unit-tested). Base 22pt body /
/// 23pt question (a panel may let it grow up to `maxBody` when there is room); steps down 1pt at a time to the floor 15 / 17; below that the panel scrolls.
/// The left (context) and right (question) panels each run this on their own.
///
/// Height is estimated from one measurement at the base size: wrapped text grows with the square
/// of the size (more lines AND taller lines at a fixed width).
struct FocusTextFit: Equatable {
    static let baseBody: CGFloat = 22
    static let baseQuestion: CGFloat = 23
    static let floorBody: CGFloat = 15
    static let floorQuestion: CGFloat = 17
    /// The right (question) panel grows its text up to this when it has room.
    static let rightMaxBody: CGFloat = 28
    static let growMargin: CGFloat = 0.94
    /// Option descriptions: readable, not footnotes.
    static let detailScale: CGFloat = 0.82

    let body: CGFloat
    let question: CGFloat
    /// Even the floor does not fit: the panel scrolls.
    let scrolls: Bool
    /// The hidden copy `FocusFittedPanel` lays out to measure: it must not build live text boxes.
    var isMeasuring = false

    static let base = FocusTextFit(body: baseBody, question: baseQuestion, scrolls: false)
    static let measuring = FocusTextFit(body: baseBody, question: baseQuestion, scrolls: false, isMeasuring: true)

    /// `heightAtBase`: the content's natural height drawn at the base sizes.
    /// `maxBody` above `baseBody` lets a panel with spare room grow its text (the right panel: 28).
    /// `shrink`: points to take off the start size after the drawn content was seen to overflow anyway
    /// (the square-law estimate is only an estimate).
    static func fit(heightAtBase: CGFloat, available: CGFloat, maxBody: CGFloat = baseBody, shrink: CGFloat = 0) -> FocusTextFit {
        guard heightAtBase > 0, available > 0 else { return base }
        var body = max(floorBody, max(baseBody, maxBody) - shrink)
        while body >= floorBody {
            let ratio = body / baseBody
            // Growing past base keeps a margin: the square-law estimate is rougher the further it reaches.
            let room = body > baseBody ? available * growMargin : available
            if heightAtBase * ratio * ratio <= room {
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

    /// A long question (a paragraph, not a line) drops to the body size so the options below stay in view.
    static let longQuestionChars = 140
    static func questionSize(for text: String, fit: FocusTextFit) -> CGFloat {
        text.count > longQuestionChars ? fit.body : fit.question
    }
}
