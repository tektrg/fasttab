import Foundation
import Testing
@testable import AgentBar

/// Focus mode's "Go to …" button: the agent's home by host, or why it can't be reached (never a silent no-op).
struct FocusDestinationTests {
    typealias F = AgentListFixtures

    @Test func aLocalHerdrPaneIsReachable() {
        let destination = FocusDestination(agent: F.agent("a", paneId: "w3:p2"))
        #expect(destination == FocusDestination(label: "herdr pane", isEnabled: true, reason: nil))
        #expect(destination.buttonTitle == "Go to herdr pane")
    }

    @Test func anAirPaneIsDisabledWithTheReason() {
        let destination = FocusDestination(agent: F.agent("a", paneId: "air-m1:w3:p2"))
        #expect(!destination.isEnabled)
        #expect(destination.reason == "Runs on Air — open it there")
        #expect(destination.buttonTitle == "Runs on Air")
    }

    @Test func aPaneThatCannotBeFocusedHasNoHome() {
        let destination = FocusDestination(agent: F.agent("a", canFocus: false))
        #expect(!destination.isEnabled)
        #expect(destination.reason == FocusDestination.noHomeReason)
    }

    @Test func claudeDesktopLiveAndSleeping() {
        var live = F.agent("d")
        live.host = .claudeDesktop(openURL: nil)
        #expect(FocusDestination(agent: live).buttonTitle == "Go to Claude Desktop")
        var sleeping = F.agent("s", section: .sleeping)
        sleeping.host = .claudeDesktop(openURL: nil)
        let destination = FocusDestination(agent: sleeping)
        #expect(destination.isEnabled)
        #expect(destination.buttonTitle == "Open in Claude")
    }

    @Test func tmuxNamesTheSessionAndNoTargetHasNoHome() {
        var cli = F.agent("c")
        cli.host = .claudeCLI(tmuxTarget: "work:@1.%3")
        #expect(FocusDestination(agent: cli).buttonTitle == "Go to tmux · work")
        cli.host = .claudeCLI(tmuxTarget: nil)
        #expect(!FocusDestination(agent: cli).isEnabled)
        #expect(FocusDestination(agent: cli).reason == FocusDestination.noHomeReason)
    }
}
