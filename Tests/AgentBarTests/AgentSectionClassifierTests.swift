import Testing
@testable import AgentBar

struct AgentSectionClassifierTests {
    private func section(hook: String?, screen: String?, inNeedsYou: Bool = false) -> AgentSection {
        AgentSectionClassifier.section(hookState: hook, screenState: screen, paneIsInDashboardNeedsYou: inNeedsYou)
    }

    @Test func screenNeedingAHumanIsNeedsYouWhateverTheHookSays() {
        #expect(section(hook: "blocked", screen: "NEEDS_HUMAN") == .needsYou)
        #expect(section(hook: "idle", screen: "NEEDS_HUMAN") == .needsYou)
        #expect(section(hook: "working", screen: "NEEDS_HUMAN") == .needsYou)
        #expect(section(hook: nil, screen: "NEEDS_HUMAN") == .needsYou)
    }

    @Test func dashboardNeedsYouEntryWinsEvenWithoutScreenConfirmation() {
        // Hook says blocked, screen could not be read: the dashboard fails open and lists it.
        #expect(section(hook: "blocked", screen: nil, inNeedsYou: true) == .needsYou)
        #expect(section(hook: "blocked", screen: "UNKNOWN", inNeedsYou: true) == .needsYou)
    }

    @Test func hookWorkingIsWorkingEvenWhenScreenReadsWaitingOrUnknown() {
        #expect(section(hook: "working", screen: "WAITING") == .working)
        #expect(section(hook: "working", screen: "UNKNOWN") == .working)
        #expect(section(hook: "working", screen: nil) == .working)
    }

    @Test func activeScreenIsWorkingEvenWhenHookSaysIdle() {
        #expect(section(hook: "idle", screen: "ACTIVE") == .working)
        #expect(section(hook: nil, screen: "ACTIVE") == .working)
    }

    @Test func hookBlockedButScreenWaitingIsIdleNotNeedsYou() {
        // The hook's "blocked" also fires ~60s after a turn ends; the screen decides.
        #expect(section(hook: "blocked", screen: "WAITING") == .idle)
    }

    @Test func everythingElseIsIdle() {
        #expect(section(hook: "idle", screen: "WAITING") == .idle)
        #expect(section(hook: nil, screen: "UNKNOWN") == .idle)
        #expect(section(hook: nil, screen: nil) == .idle)
    }

    @Test func sectionsAreOrderedForDisplay() {
        #expect(AgentSection.allCases.sorted() == [.needsYou, .working, .idle, .ended])
    }
}
