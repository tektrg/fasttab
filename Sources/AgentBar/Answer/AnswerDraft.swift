import Foundation

/// What was chosen or typed on the card when the answer was sent.
struct AnswerDraft: Equatable, Sendable {
    let identity: QuestionIdentity
    let otherText: String
    let checkedIndices: Set<Int>
    let highlightedPosition: Int
}
