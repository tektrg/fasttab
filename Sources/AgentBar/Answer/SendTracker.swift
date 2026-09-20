import Foundation

/// What was decided on a card when it was sent: kept for a retry, and named by the prompt it answered.
protocol SendDraft: Equatable, Sendable {
    associatedtype Identity: Hashable & Sendable
    var identity: Identity { get }
}

extension AnswerDraft: SendDraft {}

/// Which agents have a decision on its way (an answer, an approval), and what is known
/// about the ones just decided. Pure bookkeeping for the card models; time comes in as an argument.
///
/// An answer is "on its way" from the press until the dashboard has replied,
/// and then, unless the reply named a next question, until the dashboard's own
/// view (up to ~15s behind the pane) has moved on. Nothing waits longer than
/// `expirySeconds`: a stuck spinner is worse than a row that can be pressed again
/// (the dashboard re-checks the pane before typing, so a second press is refused,
/// never doubled).
struct SendTracker<Draft: SendDraft, Next: Equatable & Sendable> {
    typealias Identity = Draft.Identity

    static var expirySeconds: TimeInterval { 20 }

    struct Flight: Equatable {
        let token: Int
        let startedAt: Date
        /// What the row says while it waits, e.g. "approval" (empty: the default wording).
        let tag: String
    }

    /// A question that has been answered; the dashboard may keep showing it for a while.
    struct Settled: Equatable {
        let identity: Identity
        /// More questions answered by the same send (a whole form): the dashboard, up to ~15s behind,
        /// may still show any of them.
        let alsoAnswered: Set<Identity>
        /// What the reply named as coming next (the next question of a form, another prompt), if anything.
        let next: Next?
        let at: Date
        /// The tag the send carried (see `Flight.tag`).
        let tag: String

        func covers(_ current: Identity) -> Bool { identity == current || alsoAnswered.contains(current) }
    }

    private(set) var flights: [String: Flight] = [:]
    private(set) var settled: [String: Settled] = [:]
    private var drafts: [String: Draft] = [:]
    private var lastToken = 0

    // MARK: - Sending

    /// Starts an answer for `agentID`; nil (nothing started) when one is already on its way.
    mutating func begin(agentID: String, tag: String = "", at now: Date) -> Int? {
        guard flights[agentID] == nil else { return nil }
        lastToken += 1
        flights[agentID] = Flight(token: lastToken, startedAt: now, tag: tag)
        drafts[agentID] = nil
        return lastToken
    }

    /// The dashboard took the answer. False when this send is no longer the one being tracked.
    mutating func succeeded(
        agentID: String, token: Int, identity: Identity, alsoAnswered: Set<Identity> = [], next: Next?, at now: Date
    ) -> Bool {
        guard let flight = flights[agentID], flight.token == token else { return false }
        flights[agentID] = nil
        settled[agentID] = Settled(identity: identity, alsoAnswered: alsoAnswered, next: next, at: now, tag: flight.tag)
        return true
    }

    /// The answer did not go through: the row is free again and `draft` is kept for the retry.
    mutating func failed(agentID: String, token: Int, draft: Draft) -> Bool {
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

    /// The tag of the decision the row is waiting on (see `isAwaiting`); nil when it is not waiting.
    func awaitingTag(agentID: String, showing current: Identity?, now: Date) -> String? {
        guard isAwaiting(agentID: agentID, showing: current, now: now) else { return nil }
        return flights[agentID]?.tag ?? settled[agentID]?.tag
    }

    /// The row shows "Sending answer…": the answer is on its way, or was taken and
    /// the dashboard still shows that question with no next one to answer.
    func isAwaiting(agentID: String, showing current: Identity?, now: Date) -> Bool {
        if flights[agentID] != nil { return true }
        guard let current, let settledAnswer = settled[agentID], settledAnswer.covers(current), settledAnswer.next == nil else { return false }
        return now.timeIntervalSince(settledAnswer.at) < Self.expirySeconds
    }

    /// True while the dashboard's `current` question is one already answered.
    func hasAnswered(agentID: String, _ current: Identity) -> Bool {
        settled[agentID]?.covers(current) == true
    }

    /// The question to answer now when the dashboard still shows the answered `current` one.
    func nextQuestion(agentID: String, after current: Identity) -> Next? {
        guard let settledAnswer = settled[agentID], settledAnswer.covers(current) else { return nil }
        return settledAnswer.next
    }

    /// The draft kept from a failed send, when it is for `identity`; it is given back once.
    mutating func takeDraft(agentID: String, for identity: Identity) -> Draft? {
        guard let draft = drafts[agentID], draft.identity == identity else { return nil }
        drafts[agentID] = nil
        return draft
    }

    // MARK: - Following the dashboard

    /// An answered question stops being remembered once the dashboard shows another one (or none).
    /// Flights are not dropped with their row: a reply still has to be told, and every flight expires.
    mutating func settle(currentQuestions: [String: Identity]) {
        settled = settled.filter { agentID, answered in currentQuestions[agentID].map(answered.covers) == true }
    }

    mutating func reset() {
        flights = [:]
        settled = [:]
        drafts = [:]
    }
}

/// The answer card's tracker: identities are questions, `next` a question, the draft what was typed.
typealias AnswerSendTracker = SendTracker<AnswerDraft, AnswerableQuestion>
