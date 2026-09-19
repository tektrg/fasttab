import Foundation

/// Which agents have an answer on its way, and what is known about the ones just
/// answered. Pure bookkeeping for `AnswerCardModel`; time comes in as an argument.
///
/// An answer is "on its way" from the press until the dashboard has replied,
/// and then, unless the reply named a next question, until the dashboard's own
/// view (up to ~15s behind the pane) has moved on. Nothing waits longer than
/// `expirySeconds`: a stuck spinner is worse than a row that can be pressed again
/// (the dashboard re-checks the pane before typing, so a second press is refused,
/// never doubled).
struct AnswerSendTracker {
    static let expirySeconds: TimeInterval = 20

    struct Flight: Equatable {
        let token: Int
        let startedAt: Date
    }

    /// A question that has been answered; the dashboard may keep showing it for a while.
    struct Settled: Equatable {
        let identity: QuestionIdentity
        /// The next question of a multi-question form, when the reply carried one.
        let next: AnswerableQuestion?
        let at: Date
    }

    private(set) var flights: [String: Flight] = [:]
    private(set) var settled: [String: Settled] = [:]
    private var drafts: [String: AnswerDraft] = [:]
    private var lastToken = 0

    // MARK: - Sending

    /// Starts an answer for `agentID`; nil (nothing started) when one is already on its way.
    mutating func begin(agentID: String, at now: Date) -> Int? {
        guard flights[agentID] == nil else { return nil }
        lastToken += 1
        flights[agentID] = Flight(token: lastToken, startedAt: now)
        drafts[agentID] = nil
        return lastToken
    }

    /// The dashboard took the answer. False when this send is no longer the one being tracked.
    mutating func succeeded(agentID: String, token: Int, identity: QuestionIdentity, next: AnswerableQuestion?, at now: Date) -> Bool {
        guard flights[agentID]?.token == token else { return false }
        flights[agentID] = nil
        settled[agentID] = Settled(identity: identity, next: next, at: now)
        return true
    }

    /// The answer did not go through: the row is free again and `draft` is kept for the retry.
    mutating func failed(agentID: String, token: Int, draft: AnswerDraft) -> Bool {
        guard flights[agentID]?.token == token else { return false }
        flights[agentID] = nil
        drafts[agentID] = draft
        return true
    }

    /// No reply in time: the row is free again. False when the send had already ended.
    mutating func expire(agentID: String, token: Int) -> Bool {
        guard flights[agentID]?.token == token else { return false }
        flights[agentID] = nil
        return true
    }

    // MARK: - Asking

    /// The row shows "Sending answer…": the answer is on its way, or was taken and
    /// the dashboard still shows that question with no next one to answer.
    func isAwaiting(agentID: String, showing current: QuestionIdentity?, now: Date) -> Bool {
        if flights[agentID] != nil { return true }
        guard let settledAnswer = settled[agentID], settledAnswer.identity == current, settledAnswer.next == nil else { return false }
        return now.timeIntervalSince(settledAnswer.at) < Self.expirySeconds
    }

    /// True while the dashboard's `current` question is one already answered.
    func hasAnswered(agentID: String, _ current: QuestionIdentity) -> Bool {
        settled[agentID]?.identity == current
    }

    /// The question to answer now when the dashboard still shows the answered `current` one.
    func nextQuestion(agentID: String, after current: QuestionIdentity) -> AnswerableQuestion? {
        guard let settledAnswer = settled[agentID], settledAnswer.identity == current else { return nil }
        return settledAnswer.next
    }

    /// The draft kept from a failed send, when it is for `identity`; it is given back once.
    mutating func takeDraft(agentID: String, for identity: QuestionIdentity) -> AnswerDraft? {
        guard let draft = drafts[agentID], draft.identity == identity else { return nil }
        drafts[agentID] = nil
        return draft
    }

    // MARK: - Following the dashboard

    /// An answered question stops being remembered once the dashboard shows another one (or none).
    /// Flights are not dropped with their row: a reply still has to be told, and every flight expires.
    mutating func settle(currentQuestions: [String: QuestionIdentity]) {
        settled = settled.filter { agentID, answered in currentQuestions[agentID] == answered.identity }
    }

    mutating func reset() {
        flights = [:]
        settled = [:]
        drafts = [:]
    }
}
