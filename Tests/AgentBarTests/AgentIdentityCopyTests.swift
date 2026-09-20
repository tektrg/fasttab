import Foundation
import Testing
@testable import AgentBar

@MainActor
struct AgentIdentityCopyTests {
    typealias A = AnswerFixtures
    typealias F = AgentListFixtures

    // MARK: - The text

    @Test func theTextHasOneLabelledLinePerKnownFact() {
        let text = AgentIdentityText.text(
            label: "fix-login", paneId: "w6:pX", projectName: "command-bar-macos", cwd: "/Users/me/command-bar-macos", sessionId: "s-1"
        )
        #expect(text == """
        Agent: fix-login
        Pane: w6:pX
        Project: command-bar-macos
        Folder: /Users/me/command-bar-macos
        Session: s-1
        """)
    }

    @Test func factsThatAreMissingOrBlankLeaveTheirLineOut() {
        let text = AgentIdentityText.text(label: "  ", paneId: "w1:a", projectName: nil, cwd: "", sessionId: nil)
        #expect(text == "Pane: w1:a")
    }

    @Test func aSnapshotBuildsItsTextFromItsFields() {
        let agent = F.agent("a", label: "alpha", project: "proj")
        #expect(agent.identityText == "Agent: alpha\nPane: w1:a\nProject: proj")
    }

    // MARK: - The copier

    private final class Pasteboard { var writes: [String] = [] }

    @Test func copyWritesToThePasteboardAndShowsFeedbackThatClears() async {
        let pasteboard = Pasteboard()
        let copier = IdentityCopier(feedbackSeconds: 0.05, writeToPasteboard: { pasteboard.writes.append($0) })
        copier.copy("Agent: a", for: "a")
        #expect(pasteboard.writes == ["Agent: a"])
        #expect(copier.copiedAgentID == "a")
        await waitUntil { copier.copiedAgentID == nil }
        #expect(copier.copiedAgentID == nil)
    }

    @Test func aSecondCopyKeepsTheFeedbackForItsFullTime() async {
        let copier = IdentityCopier(feedbackSeconds: 0.2, writeToPasteboard: { _ in })
        copier.copy("x", for: "a")
        try? await Task.sleep(for: .milliseconds(120))
        copier.copy("y", for: "b")
        try? await Task.sleep(for: .milliseconds(120))   // 240ms after the first, 120ms after the second
        #expect(copier.copiedAgentID == "b")
    }

    @Test func copyingNothingDoesNothing() {
        let pasteboard = Pasteboard()
        let copier = IdentityCopier(writeToPasteboard: { pasteboard.writes.append($0) })
        copier.copy("", for: "a")
        #expect(pasteboard.writes.isEmpty)
        #expect(copier.copiedAgentID == nil)
    }

    // MARK: - From the panel

    private func makeRig(_ agents: [AgentSnapshot], pasteboard: Pasteboard) -> AgentPanelModel {
        let defaults = makeScratchDefaults("identity-copy")
        let model = AgentPanelModel(
            store: FrecencyStore(defaults: defaults), triageStore: TriageStore(defaults: defaults),
            answer: AnswerCardModel(loadSessionContext: { _ in .empty }, openFile: { _ in }),
            copier: IdentityCopier(writeToPasteboard: { pasteboard.writes.append($0) }),
            now: { F.now }
        )
        model.statusSource = AnswerFakeSource()
        model.receive(F.snapshot(agents))
        return model
    }

    @Test func theRowCopyIconCopiesThatRowsDetails() {
        let pasteboard = Pasteboard()
        let agent = F.agent("a", label: "alpha", project: "proj")
        let model = makeRig([agent], pasteboard: pasteboard)
        model.copyIdentity(of: agent)
        #expect(pasteboard.writes == ["Agent: alpha\nPane: w1:a\nProject: proj"])
        #expect(model.copier.copiedAgentID == "a")
    }

    @Test func theOpenAnswerCardCopiesItsAgentsDetailsAndNoCardMeansNothingCopied() {
        let pasteboard = Pasteboard()
        var agent = A.blockedAgent("q", blocker: .question(A.question()))
        agent.sessionId = "sess-9"
        let model = makeRig([agent], pasteboard: pasteboard)
        #expect(!model.copyOpenCardIdentity())   // no card: ⌘C is left to the field
        #expect(pasteboard.writes.isEmpty)
        model.press(.answer, on: "q")
        #expect(model.copyOpenCardIdentity())
        #expect(pasteboard.writes == ["Agent: agent q\nPane: w1:q\nProject: proj\nSession: sess-9"])
        #expect(model.copier.copiedAgentID == "q")
    }

    @Test func showingThePanelAgainClearsTheFeedback() {
        let pasteboard = Pasteboard()
        let agent = F.agent("a")
        let model = makeRig([agent], pasteboard: pasteboard)
        model.copyIdentity(of: agent)
        model.resetForShow()
        #expect(model.copier.copiedAgentID == nil)
    }
}
