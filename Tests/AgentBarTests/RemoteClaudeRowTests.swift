import Foundation
import Testing
@testable import AgentBar

/// A Claude agent on another machine (the Air) is first-class: never hidden by "Show non-Claude panes", never
/// dimmed, though it has no hook data (the hook cache is this Mac's only). Its Message card takes no images:
/// the dashboard's `acceptsImages: false` (the attachment file is on this Mac's disk; the send would be refused).
struct RemoteClaudeRowTests {
    typealias S = StatusOnlyFixtures

    private func paneRow(
        paneId: String = "air-m1:w8:p3", kind: String?, hasHookData: Bool = false, acceptsImages: Bool? = nil
    ) -> String {
        let kindJson = kind.map { "\"\($0)\"" } ?? "null"
        let imagesJson = acceptsImages.map { "\"acceptsImages\": \($0)," } ?? ""
        return """
        {"paneId": "\(paneId)", "label": "row", "cwd": "/p", "hasHookData": \(hasHookData),
         "agentSession": "s-\(paneId)", "source": "herdr", "rowId": "s-\(paneId)", "agentKind": \(kindJson), \(imagesJson)
         "messageVia": "pane", "messageRefusal": null}
        """
    }

    private func row(_ json: String) throws -> AgentSnapshot {
        try #require(try S.snapshot(agents: [json], needsYou: []).agents.first)
    }

    private var hidingNonClaude: AgentListSettings {
        var settings = AgentListSettings.standard
        settings.showsNonClaudePanes = false
        return settings
    }

    // MARK: - FIX B: "is Claude", not "has hook data"

    @Test func anAirClaudeRowIsNeitherHiddenNorDimmed() throws {
        let agent = try row(paneRow(kind: "claude"))
        #expect(!agent.hasHookData)
        #expect(agent.isClaude)
        #expect(hidingNonClaude.applying(to: [agent]).map(\.id) == [agent.id])
        #expect(AgentRowView.dimming(of: agent, isSelected: false) == 1)
    }

    @Test func aBestGuessNonClaudePaneIsStillHiddenAndDimmed() throws {
        for kind in ["opencode", "gemini", nil] {
            let agent = try row(paneRow(paneId: "w1:p2", kind: kind))
            #expect(agent.isBestGuessNonClaudePane)
            #expect(hidingNonClaude.applying(to: [agent]).isEmpty)
            #expect(AgentRowView.dimming(of: agent, isSelected: false) == 0.7)
        }
    }

    @Test func anOpenCodePaneWithExactStatusKeepsTodaysLook() throws {
        let agent = try row(paneRow(paneId: "w1:p2", kind: "opencode", hasHookData: true))
        #expect(!agent.isClaude)
        #expect(!agent.isBestGuessNonClaudePane)
        #expect(hidingNonClaude.applying(to: [agent]).map(\.id) == [agent.id])
        #expect(AgentRowView.dimming(of: agent, isSelected: false) == 1)
    }

    @Test func aStatusOnlySessionCountsAsClaude() throws {
        #expect(try row(S.desktopRow()).isClaude)
    }

    // MARK: - FIX A: no image attach for an agent on another machine

    @Test func theDashboardFlagReachesTheSnapshot() throws {
        #expect(!(try row(paneRow(kind: "claude", acceptsImages: false))).acceptsImages)
        #expect(try row(paneRow(paneId: "w1:p1", kind: "claude", hasHookData: true, acceptsImages: true)).acceptsImages)
        // An older dashboard without the flag keeps today's behaviour (the server still refuses remote images).
        #expect(try row(paneRow(paneId: "w1:p1", kind: "claude", hasHookData: true)).acceptsImages)
        // null / a wrong type reads as absent (lenient decode), never fails the whole row.
        for raw in ["null", "\"no\"", "0"] {
            let json = paneRow(paneId: "w1:p1", kind: "claude", hasHookData: true)
                .replacingOccurrences(of: "\"messageVia\"", with: "\"acceptsImages\": \(raw), \"messageVia\"")
            #expect(try row(json).acceptsImages)
        }
    }

    @Test func aRemoteRowsCardTakesNoImagesAndSaysSo() throws {
        let agent = try row(paneRow(kind: "claude", acceptsImages: false))
        var card = MessageCard(agent: agent, route: .pane(paneId: agent.paneId ?? ""), rowId: "s-air")
        card.addImages([Self.image()])
        #expect(card.images.isEmpty)
        #expect(!card.acceptsImages)
        #expect(card.placeholder.contains("no images"))
        #expect(!card.placeholder.contains("drop an image"))
    }

    @Test func aLocalRowsCardStillTakesImages() throws {
        let agent = try row(paneRow(paneId: "w1:p1", kind: "claude", hasHookData: true, acceptsImages: true))
        var card = MessageCard(agent: agent, route: .pane(paneId: "w1:p1"), rowId: "s-w1:p1")
        card.addImages([Self.image()])
        #expect(card.images.count == 1)
        #expect(card.placeholder.contains("drop an image"))
    }

    private static func image() -> MessageImage {
        MessageImage(id: UUID(), data: Data([1]), contentType: "image/png", thumbnail: Data([1]))
    }
}
