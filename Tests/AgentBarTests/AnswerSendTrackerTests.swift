import Foundation
import Testing
@testable import AgentBar

/// Which answers are on their way, per agent, and when a row stops waiting.
struct AnswerSendTrackerTests {
    typealias A = AnswerFixtures
    private let now = Date(timeIntervalSince1970: 1_000)
    private let fruit = A.question()
    private var identity: QuestionIdentity { fruit.identity }

    private func draft() -> AnswerDraft {
        AnswerDraft(identity: identity, otherText: "typed", checkedIndices: [1], highlightedPosition: 1)
    }

    private struct Refused: Error {}

    /// Starts a send that is expected to be accepted.
    private func begin(_ tracker: inout AnswerSendTracker, _ agentID: String) throws -> Int {
        guard let token = tracker.begin(agentID: agentID, at: now) else { throw Refused() }
        return token
    }

    @Test func aSendIsPerAgentSoOneAgentsAnswerNeverBlocksAnother() throws {
        var tracker = AnswerSendTracker()
        let first = try begin(&tracker, "a")
        let secondForSameAgent = tracker.begin(agentID: "a", at: now)
        #expect(secondForSameAgent == nil)          // no second answer for the same agent
        let otherAgent = tracker.begin(agentID: "b", at: now)
        #expect(otherAgent != nil)
        #expect(tracker.isAwaiting(agentID: "a", showing: identity, now: now))
        #expect(!tracker.isAwaiting(agentID: "c", showing: identity, now: now))
        let expired = tracker.expire(agentID: "a", token: first)
        #expect(expired)
        #expect(!tracker.isAwaiting(agentID: "a", showing: identity, now: now))
    }

    @Test func aSpinnerShowsWhateverQuestionTheDashboardIsShowingWhileTheReplyIsAwaited() {
        var tracker = AnswerSendTracker()
        _ = tracker.begin(agentID: "a", at: now)
        #expect(tracker.isAwaiting(agentID: "a", showing: nil, now: now))
    }

    @Test func successKeepsTheRowWaitingUntilTheDashboardShowsSomethingElseOrTheExpiry() throws {
        var tracker = AnswerSendTracker()
        let token = try begin(&tracker, "a")
        let accepted = tracker.succeeded(agentID: "a", token: token, identity: identity, next: nil, at: now)
        #expect(accepted)
        #expect(tracker.isAwaiting(agentID: "a", showing: identity, now: now + 5))
        #expect(tracker.hasAnswered(agentID: "a", identity))
        #expect(!tracker.isAwaiting(agentID: "a", showing: identity, now: now + AnswerSendTracker.expirySeconds + 1))
        tracker.settle(currentQuestions: ["a": QuestionIdentity(title: "Colour", question: "Which colour?")])
        #expect(!tracker.hasAnswered(agentID: "a", identity))
    }

    @Test func aWholeFormSendKeepsTheRowWaitingWhicheverOfItsQuestionsTheDashboardStillShows() throws {
        var tracker = AnswerSendTracker()
        let token = try begin(&tracker, "a")
        let second = A.question(title: "Colour", question: "Which colour?").identity
        let third = A.question(title: "Size", question: "Which size?").identity
        let accepted = tracker.succeeded(agentID: "a", token: token, identity: third, alsoAnswered: [identity, second, third], next: nil, at: now)
        #expect(accepted)
        for shown in [identity, second, third] {
            #expect(tracker.isAwaiting(agentID: "a", showing: shown, now: now))
            #expect(tracker.hasAnswered(agentID: "a", shown))
        }
        let unrelated = A.question(title: "Other", question: "Something new?").identity
        #expect(!tracker.isAwaiting(agentID: "a", showing: unrelated, now: now))
        tracker.settle(currentQuestions: ["a": second])
        #expect(tracker.hasAnswered(agentID: "a", second))      // still one of the answered ones
        tracker.settle(currentQuestions: ["a": unrelated])
        #expect(!tracker.hasAnswered(agentID: "a", second))     // the dashboard moved on: forgotten
    }

    @Test func aNextQuestionMeansNoSpinnerAndItIsWhatOpens() throws {
        var tracker = AnswerSendTracker()
        let token = try begin(&tracker, "a")
        let second = A.question(title: "Colour", question: "Which colour?")
        let accepted = tracker.succeeded(agentID: "a", token: token, identity: identity, next: second, at: now)
        #expect(accepted)
        #expect(!tracker.isAwaiting(agentID: "a", showing: identity, now: now))
        #expect(tracker.nextQuestion(agentID: "a", after: identity) == second)
        #expect(tracker.nextQuestion(agentID: "a", after: second.identity) == nil)
    }

    @Test func aFailureFreesTheRowAndKeepsTheDraftForTheSameQuestionOnce() throws {
        var tracker = AnswerSendTracker()
        let token = try begin(&tracker, "a")
        let accepted = tracker.failed(agentID: "a", token: token, draft: draft())
        #expect(accepted)
        #expect(!tracker.isAwaiting(agentID: "a", showing: identity, now: now))
        let forOther = tracker.takeDraft(agentID: "a", for: QuestionIdentity(title: "Other", question: "Other?"))
        #expect(forOther == nil)
        let taken = tracker.takeDraft(agentID: "a", for: identity)
        #expect(taken == draft())
        let takenAgain = tracker.takeDraft(agentID: "a", for: identity)
        #expect(takenAgain == nil)
    }

    @Test func aLateReplyForAnEndedSendChangesNothing() throws {
        var tracker = AnswerSendTracker()
        let token = try begin(&tracker, "a")
        let expired = tracker.expire(agentID: "a", token: token)
        let lateFailure = tracker.failed(agentID: "a", token: token, draft: draft())
        let lateSuccess = tracker.succeeded(agentID: "a", token: token, identity: identity, next: nil, at: now)
        let expiredAgain = tracker.expire(agentID: "a", token: token)
        #expect(expired)
        #expect(!lateFailure && !lateSuccess && !expiredAgain)
        // And a newer send is not confused with the old one's token.
        let newer = try begin(&tracker, "a")
        #expect(newer != token)
        let staleFailure = tracker.failed(agentID: "a", token: token, draft: draft())
        #expect(!staleFailure)
        #expect(tracker.isAwaiting(agentID: "a", showing: identity, now: now))
    }

    @Test func resetForgetsEverything() throws {
        var tracker = AnswerSendTracker()
        let token = try begin(&tracker, "a")
        _ = tracker.succeeded(agentID: "a", token: token, identity: identity, next: nil, at: now)
        _ = tracker.begin(agentID: "b", at: now)
        tracker.reset()
        #expect(!tracker.isAwaiting(agentID: "b", showing: nil, now: now))
        #expect(!tracker.hasAnswered(agentID: "a", identity))
    }

    // MARK: - What a row says while it waits (permission decisions)

    @Test func theRowRemembersWhichKindOfDecisionItIsWaitingOn() {
        var tracker = PermissionSendTracker()
        let box = PermissionFixtures.bash.identity
        guard let token = tracker.begin(agentID: "a", tag: "denial", at: now) else {
            Issue.record("a send should start")
            return
        }
        #expect(tracker.awaitingTag(agentID: "a", showing: box, now: now) == "denial")
        let taken = tracker.succeeded(agentID: "a", token: token, identity: box, next: nil, at: now)
        #expect(taken)
        // The reply is in, the dashboard still shows the box: still waiting, still a denial.
        #expect(tracker.awaitingTag(agentID: "a", showing: box, now: now + 3) == "denial")
        #expect(tracker.awaitingTag(agentID: "a", showing: nil, now: now + 3) == nil)
        #expect(tracker.awaitingTag(agentID: "a", showing: box, now: now + PermissionSendTracker.expirySeconds + 1) == nil)
    }

    @Test func aBoxNamedAsNextIsNotWaitedOn() {
        var tracker = PermissionSendTracker()
        let box = PermissionFixtures.bash.identity
        guard let token = tracker.begin(agentID: "a", tag: "approval", at: now) else {
            Issue.record("a send should start")
            return
        }
        _ = tracker.succeeded(agentID: "a", token: token, identity: box, next: PermissionFixtures.oneOff, at: now)
        #expect(tracker.awaitingTag(agentID: "a", showing: box, now: now) == nil)
        #expect(tracker.nextQuestion(agentID: "a", after: box) == PermissionFixtures.oneOff)
    }
}
