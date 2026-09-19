import Foundation

/// What the user picked, in the words of `POST /api/answer`.
enum AnswerChoice: Equatable, Sendable {
    /// Option numbers as the picker shows them (never the free-text row).
    case select([Int])
    /// Free text for the picker's Other row.
    case text(String)

    /// `{"type":"select","indices":[...]}` or `{"type":"text","value":"..."}`.
    var jsonObject: [String: Any] {
        switch self {
        case .select(let indices): ["type": "select", "indices": indices.sorted()]
        case .text(let value): ["type": "text", "value": value]
        }
    }
}

/// How the dashboard answered an answer request.
enum AnswerResult: Equatable, Sendable {
    /// The picker took it. `next` is the following question of a multi-question
    /// form, when the dashboard saw one open.
    case sent(next: AnswerableQuestion?)
    /// Refused or unreachable, in the dashboard's own words when it gave any.
    /// Nothing is retried: the user decides what to do.
    case failed(String)
}
