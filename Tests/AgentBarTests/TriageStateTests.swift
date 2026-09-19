import Foundation
import Testing
@testable import AgentBar

struct TriageStateTests {
    typealias F = AgentListFixtures

    private func agents(needsYou: [String] = [], working: [String] = [], ended: [String] = []) -> [AgentSnapshot] {
        needsYou.map { F.agent($0, section: .needsYou) }
            + working.map { F.agent($0, section: .working) }
            + ended.map { F.agent($0, section: .ended) }
    }

    @Test func parkAndUnparkAreIdempotent() {
        var triage = TriageState.empty
        triage.park("a")
        triage.park("a")
        #expect(triage.parkedIDs == ["a"])
        triage.unpark("a")
        triage.unpark("a")
        #expect(triage.parkedIDs.isEmpty)
    }

    @Test func parkedNeedsYouAgentsMoveToParkedInPlace() {
        var triage = TriageState.empty
        triage.park("b")
        let shown = triage.applying(to: agents(needsYou: ["a", "b"], working: ["w"]))
        #expect(shown.map(\.id) == ["a", "b", "w"])
        #expect(shown.map(\.section) == [.needsYou, .parked, .working])
    }

    @Test func aWorkingAgentIsNeverShownParked() {
        var triage = TriageState.empty
        triage.park("w")
        #expect(triage.applying(to: agents(working: ["w"])).map(\.section) == [.working])
    }

    @Test func observingAParkedAgentWorkingReArmsIt() {
        var triage = TriageState.empty
        triage.park("a")
        let changed = triage.observe(agents(working: ["a"]))
        #expect(changed)
        #expect(!triage.isParked("a"))
        // It finishes later: back in Needs you, not Parked.
        #expect(triage.applying(to: agents(needsYou: ["a"])).map(\.section) == [.needsYou])
    }

    @Test func observingAParkedAgentStillWaitingKeepsItParked() {
        var triage = TriageState.empty
        triage.park("a")
        let changed = triage.observe(agents(needsYou: ["a"]))
        #expect(!changed)
        #expect(triage.isParked("a"))
    }

    @Test func agentsThatNoLongerExistArePruned() {
        var triage = TriageState.empty
        triage.park("gone")
        triage.park("here")
        let changed = triage.observe(agents(needsYou: ["here"]))
        #expect(changed)
        #expect(triage.parkedIDs == ["here"])
    }

    @Test func anEndedRowIsNotALiveAgent() {
        var triage = TriageState.empty
        triage.park("a")
        let changed = triage.observe(agents(ended: ["a"]))   // stopped and gone from the live feed
        #expect(changed)
        #expect(triage.parkedIDs.isEmpty)
    }

    @Test func observingChangesNothingWhenNothingIsParked() {
        var triage = TriageState.empty
        let changed = triage.observe(agents(needsYou: ["a"], working: ["w"]))
        #expect(!changed)
    }

    @Test func storeRoundTripsThroughItsOwnDefaultsDomain() {
        let defaults = makeScratchDefaults("triage")
        let store = TriageStore(defaults: defaults)
        #expect(store.load() == .empty)
        var triage = TriageState.empty
        triage.park("a")
        triage.park("w1:p2")
        store.save(triage)
        #expect(TriageStore(defaults: defaults).load().parkedIDs == ["a", "w1:p2"])
    }

    @Test func storeTreatsUnreadableDataAsNothingParked() {
        let defaults = makeScratchDefaults("triage-bad")
        defaults.set("not an array", forKey: TriageStore.defaultsKey)
        #expect(TriageStore(defaults: defaults).load() == .empty)
    }
}
