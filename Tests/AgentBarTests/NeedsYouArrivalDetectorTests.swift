import Testing
@testable import AgentBar

struct NeedsYouArrivalDetectorTests {
    typealias F = AgentListFixtures

    private func ids(_ agents: [AgentSnapshot]) -> [String] { agents.map(\.id) }

    @Test func firstReadingIsOnlyABaseline() {
        var detector = NeedsYouArrivalDetector()
        #expect(detector.observe([F.agent("a"), F.agent("b")]).isEmpty)
    }

    @Test func aNewAgentIsAnArrival() {
        var detector = NeedsYouArrivalDetector()
        _ = detector.observe([F.agent("a")])
        #expect(ids(detector.observe([F.agent("a"), F.agent("b")])) == ["b"])
    }

    @Test func anUnchangedReadingHasNoArrivals() {
        var detector = NeedsYouArrivalDetector()
        _ = detector.observe([F.agent("a")])
        #expect(detector.observe([F.agent("a")]).isEmpty)
        #expect(detector.observe([F.agent("a")]).isEmpty)
    }

    @Test func aDepartureIsNotAnArrivalButReturningIs() {
        var detector = NeedsYouArrivalDetector()
        _ = detector.observe([F.agent("a"), F.agent("b")])
        #expect(detector.observe([F.agent("a")]).isEmpty)
        #expect(ids(detector.observe([F.agent("a"), F.agent("b")])) == ["b"])
    }

    @Test func severalArrivalsComeBackInTheOrderGiven() {
        var detector = NeedsYouArrivalDetector()
        _ = detector.observe([F.agent("a")])
        #expect(ids(detector.observe([F.agent("c"), F.agent("a"), F.agent("b")])) == ["c", "b"])
    }

    @Test func anEmptyReadingIsAValidBaseline() {
        var detector = NeedsYouArrivalDetector()
        #expect(detector.observe([]).isEmpty)
        #expect(ids(detector.observe([F.agent("a")])) == ["a"])
    }

    @Test func feedDownAndRecoveryResetTheBaseline() {
        var detector = NeedsYouArrivalDetector()
        _ = detector.observe([F.agent("a")])
        #expect(detector.observe(nil).isEmpty)
        // The feed is back with a new agent that arrived while it was down: baseline, no peek.
        #expect(detector.observe([F.agent("a"), F.agent("b")]).isEmpty)
        #expect(ids(detector.observe([F.agent("a"), F.agent("b"), F.agent("c")])) == ["c"])
    }
}

struct CornerTabContentTests {
    typealias F = AgentListFixtures

    @Test func headlineAgreesWithTheCount() {
        #expect(CornerTabContent(count: 1, newestName: "x").headline == "1 needs you")
        #expect(CornerTabContent(count: 3, newestName: "x").headline == "3 need you")
    }

    @Test func newestArrivalIsTheOneInItsStatusShortest() {
        let old = F.agent("a", label: "old", secondsInStatus: 300)
        let fresh = F.agent("b", label: "fresh", secondsInStatus: 5)
        let content = CornerTabContent.forArrivals([old, fresh], among: [old, fresh, F.agent("c")])
        #expect(content == CornerTabContent(count: 3, newestName: "fresh"))
    }

    @Test func unknownAgeRanksLastAndTiesKeepOrder() {
        let unknown = F.agent("a", label: "unknown", secondsInStatus: nil)
        let known = F.agent("b", label: "known", secondsInStatus: 90)
        #expect(CornerTabContent.forArrivals([unknown, known], among: [unknown, known])?.newestName == "known")

        let first = F.agent("c", label: "first", secondsInStatus: 10)
        let second = F.agent("d", label: "second", secondsInStatus: 10)
        #expect(CornerTabContent.forArrivals([first, second], among: [first, second])?.newestName == "first")
    }

    @Test func noArrivalsMeansNoContent() {
        #expect(CornerTabContent.forArrivals([], among: [F.agent("a")]) == nil)
    }
}
