import Foundation
import Testing
@testable import AgentBar

struct AgentListSettingsTests {
    typealias F = AgentListFixtures
    private let hour: TimeInterval = 3_600

    private func ended(_ id: String, hoursAgo: Double) -> AgentSnapshot {
        F.agent(id, section: .ended, secondsInStatus: hoursAgo * hour)
    }

    // MARK: - Persistence

    @Test func defaultsMatchTheFormerHardCodedBehaviour() {
        let settings = AgentListSettings.load(from: makeScratchDefaults())
        #expect(settings == .standard)
        #expect(settings.endedWindowSeconds == EndedAgentMapper.endedWindowSeconds)
        #expect(settings.maxEndedRows == EndedAgentMapper.maxEndedCount)
        #expect(settings.showsNonClaudePanes)
        #expect(AgentPanelMetrics.maxListHeight(visibleRows: settings.maxVisibleRows) == AgentPanelMetrics.maxListHeight)
    }

    @Test func roundTripsThroughDefaults() {
        let defaults = makeScratchDefaults()
        let chosen = AgentListSettings(endedWindowHours: 72, maxEndedRows: 0, showsNonClaudePanes: false, maxVisibleRows: 14)
        chosen.save(to: defaults)
        #expect(AgentListSettings.load(from: defaults) == chosen)
    }

    @Test func aValueThatIsNotOneOfTheChoicesFallsBackToItsDefault() {
        let defaults = makeScratchDefaults()
        defaults.set(5, forKey: AgentListSettings.endedWindowHoursKey)       // not 1/6/24/72
        defaults.set(-3, forKey: AgentListSettings.maxEndedRowsKey)
        defaults.set(99, forKey: AgentListSettings.maxVisibleRowsKey)        // outside 6...16
        defaults.set("yes", forKey: AgentListSettings.showsNonClaudePanesKey) // wrong type
        #expect(AgentListSettings.load(from: defaults) == .standard)
    }

    @Test func oneBadValueDoesNotSpoilTheOthers() {
        let defaults = makeScratchDefaults()
        defaults.set(6, forKey: AgentListSettings.endedWindowHoursKey)
        defaults.set(7, forKey: AgentListSettings.maxEndedRowsKey)           // invalid
        let loaded = AgentListSettings.load(from: defaults)
        #expect(loaded.endedWindowHours == 6)
        #expect(loaded.maxEndedRows == 8)
    }

    @Test func everyOfferedChoiceFitsWhatTheStatusSnapshotCarries() {
        #expect(Double(AgentListSettings.endedWindowHoursChoices.max()!) * hour <= EndedAgentMapper.Limits.widest.windowSeconds)
        #expect(AgentListSettings.maxEndedRowsChoices.max()! <= EndedAgentMapper.Limits.widest.maxCount)
    }

    // MARK: - Filtering

    @Test func endedRowsPastTheWindowAreHidden() {
        let agents = [ended("a", hoursAgo: 0.5), ended("b", hoursAgo: 3), ended("c", hoursAgo: 30)]
        var settings = AgentListSettings.standard
        settings.endedWindowHours = 1
        #expect(settings.applying(to: agents).map(\.id) == ["a"])
        settings.endedWindowHours = 6
        #expect(settings.applying(to: agents).map(\.id) == ["a", "b"])
        settings.endedWindowHours = 72
        #expect(settings.applying(to: agents).map(\.id) == ["a", "b", "c"])
    }

    @Test func endedCapKeepsTheNewestAndZeroHidesTheSection() {
        let agents = (0..<6).map { ended("e\($0)", hoursAgo: Double($0)) }   // newest first
        var settings = AgentListSettings.standard
        settings.maxEndedRows = 4
        #expect(settings.applying(to: agents).map(\.id) == ["e0", "e1", "e2", "e3"])
        settings.maxEndedRows = 0
        #expect(settings.applying(to: agents).isEmpty)
    }

    @Test func liveAgentsAreNotAffectedByTheEndedChoices() {
        let live = [F.agent("n", section: .needsYou), F.agent("w", section: .working), F.agent("i", section: .parked)]
        var settings = AgentListSettings.standard
        settings.maxEndedRows = 0
        settings.endedWindowHours = 1
        #expect(settings.applying(to: live) == live)
    }

    @Test func nonClaudePanesCanBeHidden() {
        let agents = [F.agent("claude"), F.agent("shell", hasHookData: false)]
        var settings = AgentListSettings.standard
        #expect(settings.applying(to: agents).map(\.id) == ["claude", "shell"])
        settings.showsNonClaudePanes = false
        #expect(settings.applying(to: agents).map(\.id) == ["claude"])
    }

    // MARK: - Through the list builder

    @Test func theBuilderAppliesTheSettings() {
        let snapshot = F.snapshot([F.agent("w", section: .working), ended("new", hoursAgo: 2), ended("old", hoursAgo: 10)])
        #expect(F.presentation(snapshot).agents.map(\.id) == ["w", "new", "old"])

        var narrow = AgentListSettings.standard
        narrow.endedWindowHours = 6
        #expect(F.presentation(snapshot, settings: narrow).agents.map(\.id) == ["w", "new"])

        var none = AgentListSettings.standard
        none.maxEndedRows = 0
        let rows = F.presentation(snapshot, settings: none).rows
        #expect(!rows.contains(.header(.ended)))
    }

    @Test func hidingEverythingLeavesTheNoAgentsMessage() {
        let snapshot = F.snapshot([F.agent("shell", hasHookData: false)])
        var settings = AgentListSettings.standard
        settings.showsNonClaudePanes = false
        #expect(F.presentation(snapshot, settings: settings).state == .noAgents)
    }
}
