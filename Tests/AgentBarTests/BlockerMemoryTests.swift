import Foundation
import Testing
@testable import AgentBar

/// A blocked agent's Answer must not come and go as the dashboard re-reports its row.
struct BlockerMemoryTests {
    typealias A = AnswerFixtures
    let now = Date(timeIntervalSince1970: 1_000)
    let fruit = A.question()

    func agent(_ blocker: AgentBlocker?, id: String = "a") -> AgentSnapshot {
        A.blockedAgent(id, blocker: blocker)
    }

    func blockers(_ memory: inout BlockerMemory, _ agents: [AgentSnapshot], at time: Date) -> [AgentBlocker?] {
        memory.steadied(agents, now: time).map(\.blocker)
    }

    @Test func aQuestionSeenAnswerableSurvivesItsRowFlappingToAPreview() {
        var memory = BlockerMemory()
        _ = memory.steadied([agent(.question(fruit))], now: now)
        let previewOfIt = AgentBlocker.questionLoading(fruit.identity)
        #expect(blockers(&memory, [agent(previewOfIt)], at: now + 5) == [.question(fruit)])
        #expect(blockers(&memory, [agent(.questionLoading(nil))], at: now + 10) == [.question(fruit)])
    }

    @Test func aPreviewOfADifferentQuestionIsNotHeldBackByTheOldOne() {
        var memory = BlockerMemory()
        _ = memory.steadied([agent(.question(fruit))], now: now)
        let next = QuestionIdentity(title: "Colour", question: "Which colour?")
        #expect(blockers(&memory, [agent(.questionLoading(next))], at: now + 5) == [.questionLoading(next)])
    }

    @Test func aRowFlippingToBlockedHoldsTheQuestionForAShortWhileOnly() {
        var memory = BlockerMemory()
        _ = memory.steadied([agent(.question(fruit))], now: now)
        #expect(blockers(&memory, [agent(.permission)], at: now + 30) == [.question(fruit)])
        let past = now + BlockerMemory.unconfirmedGraceSeconds + 1
        #expect(blockers(&memory, [agent(.permission)], at: past) == [.permission])
    }

    @Test func aQuestionNeverSeenAnswerableStaysLoadingAndAnUnsupportedShapeIsNotHeld() {
        var memory = BlockerMemory()
        #expect(blockers(&memory, [agent(.questionLoading(nil))], at: now) == [.questionLoading(nil)])
        _ = memory.steadied([agent(.question(fruit))], now: now + 1)
        #expect(blockers(&memory, [agent(.questionNotAnswerable)], at: now + 2) == [.questionNotAnswerable])
    }

    @Test func nothingIsRememberedOnceTheAgentIsNoLongerBlocked() {
        var memory = BlockerMemory()
        _ = memory.steadied([agent(.question(fruit))], now: now)
        #expect(blockers(&memory, [agent(nil)], at: now + 5) == [nil])
        #expect(blockers(&memory, [agent(.questionLoading(nil))], at: now + 6) == [.questionLoading(nil)])
        _ = memory.steadied([agent(.question(fruit))], now: now + 7)
        #expect(blockers(&memory, [], at: now + 8) == [])   // the agent left the list
        #expect(blockers(&memory, [agent(.questionLoading(nil))], at: now + 9) == [.questionLoading(nil)])
    }

    @Test func eachAgentIsRememberedOnItsOwn() {
        var memory = BlockerMemory()
        _ = memory.steadied([agent(.question(fruit), id: "a"), agent(.permission, id: "b")], now: now)
        let steady = blockers(&memory, [agent(.questionLoading(nil), id: "a"), agent(.questionLoading(nil), id: "b")], at: now + 3)
        #expect(steady == [.question(fruit), .questionLoading(nil)])
    }

    // MARK: - Permission boxes flap the same way

    private let box = PermissionFixtures.bash

    @Test func aReviewableBoxSurvivesItsRowFlappingToPlainBlockedForAShortWhileOnly() {
        var memory = BlockerMemory()
        _ = memory.steadied([agent(.permissionReview(box))], now: now)
        #expect(blockers(&memory, [agent(.permission)], at: now + 30) == [.permissionReview(box)])
        #expect(blockers(&memory, [agent(.permission)], at: now + BlockerMemory.unconfirmedGraceSeconds + 1) == [.permission])
    }

    @Test func theHoldIsRenewedEveryTimeTheBoxIsSeenParsedAgain() {
        var memory = BlockerMemory()
        _ = memory.steadied([agent(.permissionReview(box))], now: now)
        _ = memory.steadied([agent(.permissionReview(box))], now: now + 40)
        #expect(blockers(&memory, [agent(.permission)], at: now + 80) == [.permissionReview(box)])
    }

    @Test func aRowNeverSeenParsedStaysPlain() {
        var memory = BlockerMemory()
        #expect(blockers(&memory, [agent(.permission)], at: now) == [.permission])
        #expect(blockers(&memory, [agent(.permission)], at: now + 5) == [.permission])
    }

    @Test func aBoxIsNotHeldOnceTheAgentIsNoLongerBlocked() {
        var memory = BlockerMemory()
        _ = memory.steadied([agent(.permissionReview(box))], now: now)
        _ = memory.steadied([agent(nil)], now: now + 2)
        #expect(blockers(&memory, [agent(.permission)], at: now + 4) == [.permission])
    }

    @Test func aDifferentBoxReplacesTheRememberedOne() {
        var memory = BlockerMemory()
        _ = memory.steadied([agent(.permissionReview(box))], now: now)
        _ = memory.steadied([agent(.permissionReview(PermissionFixtures.oneOff))], now: now + 2)
        #expect(blockers(&memory, [agent(.permission)], at: now + 4) == [.permissionReview(PermissionFixtures.oneOff)])
    }

    @Test func aQuestionPreviewNeverBringsBackABox() {
        var memory = BlockerMemory()
        _ = memory.steadied([agent(.permissionReview(box))], now: now)
        #expect(blockers(&memory, [agent(.questionLoading(nil))], at: now + 2) == [.questionLoading(nil)])
    }
}

/// A question or box AgentBar read off the pane itself (see `BlockerProbe`).
extension BlockerMemoryTests {
    @Test func aQuestionReadFromThePaneStandsInForARowTheDashboardHasNoBlockerFor() {
        var memory = BlockerMemory()
        memory.learn(.question(fruit), for: "a", now: now)
        #expect(blockers(&memory, [agent(nil)], at: now + 5) == [.question(fruit)])
        #expect(blockers(&memory, [agent(.questionLoading(nil))], at: now + 6) == [.question(fruit)])
    }

    @Test func aReadOfThePaneIsHeldOnlyForTheGraceAndOnlyWhileTheAgentNeedsYou() {
        var memory = BlockerMemory()
        memory.learn(.permissionReview(PermissionFixtures.bash), for: "a", now: now)
        let working = A.blockedAgent("a", blocker: nil, section: .working)
        #expect(blockers(&memory, [working], at: now + 1) == [nil])   // moved on: forgotten
        memory.learn(.permissionReview(PermissionFixtures.bash), for: "a", now: now)
        let past = now + BlockerMemory.unconfirmedGraceSeconds + 1
        #expect(blockers(&memory, [agent(nil)], at: past) == [nil])
    }

    @Test func aDashboardReportedBlockerNeverStandsInForAMissingOne() {
        var memory = BlockerMemory()
        _ = memory.steadied([agent(.question(fruit))], now: now)
        #expect(blockers(&memory, [agent(nil)], at: now + 5) == [nil])
    }

    @Test func onlyAParsedBlockerCanBeLearned() {
        var memory = BlockerMemory()
        memory.learn(.permission, for: "a", now: now)
        memory.learn(.questionLoading(nil), for: "a", now: now)
        #expect(blockers(&memory, [agent(nil)], at: now + 1) == [nil])
    }
}
