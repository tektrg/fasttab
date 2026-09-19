import Foundation
import Testing
import CommandBarKit
@testable import AgentBar

struct AgentRankingTests {
    typealias F = AgentListFixtures

    private func visited(daysAgo: Double, count: Double = 1) -> FrecencyEntry {
        let when = F.now.addingTimeInterval(-daysAgo * 86_400)
        return FrecencyEntry(count: count, lastVisit: when, cachedScore: count, cachedScoreAt: when)
    }

    private func order(_ section: AgentSection, _ ids: [String], _ frecency: [String: FrecencyEntry]) -> [String] {
        let agents = ids.map { F.agent($0, section: section) }
        return AgentRanking.ordered(agents, in: section, frecency: frecency, now: F.now).map(\.id)
    }

    @Test func higherFrecencyFirstInWorkingAndParked() {
        let frecency = ["b": visited(daysAgo: 0, count: 3), "c": visited(daysAgo: 0, count: 1)]
        #expect(order(.working, ["a", "b", "c"], frecency) == ["b", "c", "a"])
        #expect(order(.parked, ["a", "b", "c"], frecency) == ["b", "c", "a"])
    }

    @Test func recentVisitsOutweighOldOnes() {
        let frecency = ["old": visited(daysAgo: 12, count: 3), "new": visited(daysAgo: 0, count: 1)]
        #expect(order(.parked, ["old", "new"], frecency) == ["new", "old"])
    }

    @Test func tiesKeepTheClientOrder() {
        #expect(order(.parked, ["z", "y", "x"], [:]) == ["z", "y", "x"])
        let same = ["x": visited(daysAgo: 1), "y": visited(daysAgo: 1)]
        #expect(order(.parked, ["y", "x"], same) == ["y", "x"])
    }

    @Test func needsYouKeepsClientUrgencyOrder() {
        let frecency = ["b": visited(daysAgo: 0, count: 9)]
        #expect(order(.needsYou, ["a", "b"], frecency) == ["a", "b"])
    }

    @Test func endedIsNotReRanked() {
        let frecency = ["old": visited(daysAgo: 0, count: 9)]
        #expect(order(.ended, ["newest", "old"], frecency) == ["newest", "old"])
    }

    @Test func rankingAppliesPerSectionInsideTheBuiltList() {
        let snapshot = F.snapshot([
            F.agent("i1", section: .parked), F.agent("i2", section: .parked), F.agent("w1", section: .working)
        ])
        let presentation = F.presentation(snapshot, frecency: ["i2": visited(daysAgo: 0)])
        #expect(presentation.agents.map(\.id) == ["w1", "i2", "i1"])
    }

    @Test func parkedRanksByFrecencyLikeWorking() {
        let frecency = ["p2": visited(daysAgo: 0, count: 5)]
        #expect(order(.parked, ["p1", "p2", "p3"], frecency) == ["p2", "p1", "p3"])
    }
}
