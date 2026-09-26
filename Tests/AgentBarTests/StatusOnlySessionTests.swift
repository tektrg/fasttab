import Foundation
import Testing
@testable import AgentBar

/// Claude Desktop / Claude CLI sessions outside herdr (`AgentHost`): status-only rows with no pane.
/// Wire shapes mirror the dashboard's `claude_sessions.py` rows (commit 16399d2).
enum StatusOnlyFixtures {
    static let desktopSession = "8cd1ff21-3993-4667-8a2b-c1c6ad258e26"
    static let cliSession = "11111111-2222-4333-8444-555555555555"
    static let openUrl = "claude://code/continue?session=local_8a75"

    static let feeds = """
    "feeds": {"hookCache": {"refreshIntervalSec": 2, "ageSec": 0.1},
              "herdr": {"refreshIntervalSec": 5, "ageSec": 0.1},
              "paneScreen": {"refreshIntervalSec": 15, "ageSec": 0.1}}
    """

    static func desktopRow(session: String = desktopSession, status: String = "waiting", hookState: String = "blocked") -> String {
        """
        {"paneId": null, "tabId": null, "label": "Recent highlights", "cwd": "/Users/me/command-bar-macos",
         "hookState": "\(hookState)", "hookSinceSec": 30, "hasHookData": true, "agentSession": "\(session)",
         "hookReason": "Input needed", "screenState": null, "source": "claude-desktop", "sessionStatus": "\(status)",
         "hostSessionId": "local_8a75", "tmuxTarget": null, "openUrl": "\(openUrl)", "rowId": "\(session)",
         "actions": {"stop": {"enabled": false, "reason": "refused: claude-desktop session"},
                     "close": {"enabled": false}, "archive": {"enabled": true}}}
        """
    }

    static func cliRow(tmuxTarget: String?) -> String {
        let target = tmuxTarget.map { "\"\($0)\"" } ?? "null"
        return """
        {"paneId": null, "label": "cli-agent", "cwd": "/tmp/x", "hookState": "idle", "hasHookData": true,
         "agentSession": "\(cliSession)", "source": "claude-cli", "sessionStatus": "idle",
         "tmuxTarget": \(target), "openUrl": null, "rowId": "\(cliSession)"}
        """
    }

    static let desktopWaitingNeedsYou = """
    {"kind": "blocked", "paneId": null, "detail": "Input needed", "identity": "\(desktopSession)",
     "permission": null, "source": "claude-desktop", "agentSession": "\(desktopSession)", "openUrl": "\(openUrl)", "sinceSec": 12}
    """

    static func snapshot(agents: [String], needsYou: [String] = []) throws -> StatusSnapshot {
        let json = "{\(feeds), \"computed\": {\"agents\": [\(agents.joined(separator: ","))], \"needsYou\": [\(needsYou.joined(separator: ","))]}}"
        return try StatusSnapshotBuilder.snapshot(fromJSON: Data(json.utf8), fetchedAt: StatusFixtures.serverNow)
    }

    /// A status-only agent as the mapper builds it, for model/view-logic tests.
    static func desktopAgent(_ id: String = desktopSession, section: AgentSection = .needsYou) -> AgentSnapshot {
        AgentSnapshot(
            id: id, label: "desk", projectName: "proj", cwd: "/p", paneId: nil, section: section,
            statusText: "Input needed", secondsInStatus: 10, hasUnpushedCommits: false, unpushedText: nil,
            promptExcerpt: nil, canFocus: true, hasHookData: true, rowId: id, sessionId: id, actions: .none,
            blocker: nil, host: .claudeDesktop(openURL: URL(string: openUrl))
        )
    }
}

struct StatusOnlyMapperTests {
    typealias S = StatusOnlyFixtures

    @Test func aWaitingDesktopSessionIsAGenericNeedsYouRowKeyedBySession() throws {
        let snapshot = try S.snapshot(agents: [S.desktopRow()], needsYou: [S.desktopWaitingNeedsYou])
        let row = try #require(snapshot.agents.first)
        #expect(row.id == S.desktopSession)
        #expect(row.paneId == nil)
        #expect(row.sessionId == S.desktopSession)
        #expect(row.rowId == S.desktopSession)
        #expect(row.host == .claudeDesktop(openURL: URL(string: S.openUrl)))
        #expect(row.section == .needsYou)
        #expect(row.statusText == "Input needed")
        #expect(row.secondsInStatus == 12)            // the needsYou entry's clock
        #expect(row.blocker == nil)                   // nothing AgentBar can answer: no red button, no card
        #expect(row.actions == .none)                 // Done never offered
        #expect(row.canFocus)
    }

    @Test func busyIsWorkingAndIdleIsNeedsYou() throws {
        let busy = try S.snapshot(agents: [S.desktopRow(status: "busy", hookState: "working")])
        #expect(busy.agents.first?.section == .working)
        let idle = try S.snapshot(agents: [S.desktopRow(status: "idle", hookState: "idle")])
        #expect(idle.agents.first?.section == .needsYou)
        #expect(idle.agents.first?.blocker == nil)
    }

    @Test func cliSessionsCarryTheirTmuxTarget() throws {
        let inTmux = try S.snapshot(agents: [S.cliRow(tmuxTarget: "work:@3.%7")])
        #expect(inTmux.agents.first?.host == .claudeCLI(tmuxTarget: "work:@3.%7"))
        #expect(inTmux.agents.first?.host.badgeText == "CLI · tmux")
        let bare = try S.snapshot(agents: [S.cliRow(tmuxTarget: nil)])
        #expect(bare.agents.first?.host == .claudeCLI(tmuxTarget: nil))
        #expect(bare.agents.first?.host.badgeText == "CLI")
        #expect(AgentHost.herdr.badgeText == nil)
        #expect(AgentHost.claudeDesktop(openURL: nil).badgeText == "Claude Desktop")
    }

    /// Enter hands `openUrl` to NSWorkspace: only Claude.app's own session link may get there.
    @Test func onlyAClaudeSessionLinkIsKeptAsTheOpenURL() {
        let link = "claude://code/continue?session=local_8711df12-7689"
        #expect(AgentHost(source: "claude-desktop", openUrl: link, tmuxTarget: nil)
            == .claudeDesktop(openURL: URL(string: link)))
        for other in ["https://example.com/continue", "file:///Applications/Calculator.app",
                      "claude://settings", "claude://code/new?session=local_1", ""] {
            #expect(AgentHost(source: "claude-desktop", openUrl: other, tmuxTarget: nil)
                == .claudeDesktop(openURL: nil), "\(other)")
        }
    }

    @Test func aMissingSourceIsHerdrAndAHerdrRowStillNeedsItsPane() throws {
        let snapshot = try S.snapshot(agents: [
            #"{"paneId": "w1:p1", "label": "old-dashboard", "agentSession": "s1"}"#,
            #"{"paneId": null, "label": "herdr-no-pane", "source": "herdr", "agentSession": "s2"}"#,
        ])
        #expect(snapshot.agents.map(\.label) == ["old-dashboard"])
        #expect(snapshot.agents.first?.host == .herdr)
        #expect(snapshot.agents.first?.paneId == "w1:p1")
    }

    @Test func oddEntriesCostOnlyThemselves() throws {
        let snapshot = try S.snapshot(agents: [
            #"{"paneId": null, "label": "desktop-no-session", "source": "claude-desktop"}"#,
            #"{"paneId": null, "label": "future-no-pane", "source": "codex-desktop", "agentSession": "s3"}"#,
            #"{"paneId": "w1:p9", "label": "future-with-pane", "source": "codex-desktop", "agentSession": "s4"}"#,
            #"{"paneId": null, "label": "source-wrong-type", "source": 7, "agentSession": "s5"}"#,
            #"{"paneId": null, "label": "bad-url", "source": "claude-desktop", "agentSession": "s6", "openUrl": 42}"#,
            "17",
            S.desktopRow(),
        ])
        #expect(snapshot.agents.map(\.label).sorted() == ["Recent highlights", "bad-url", "future-with-pane"])
        #expect(snapshot.agent(labelled: "future-with-pane")?.host == .herdr)
        #expect(snapshot.agent(labelled: "bad-url")?.host == .claudeDesktop(openURL: nil))
    }

    @Test func aPanelessNeedsYouEntryNeverAttachesToAHerdrRow() throws {
        // Same session id on a herdr row (a pane) and a pane-less "blocked" entry: the herdr row
        // matches entries by pane only, so it is not handed the desktop session's blocker.
        let snapshot = try S.snapshot(
            agents: [#"{"paneId": "w1:p1", "label": "herdr", "agentSession": "\#(S.desktopSession)", "hookState": "working", "hasHookData": true}"#],
            needsYou: [S.desktopWaitingNeedsYou]
        )
        #expect(snapshot.agents.first?.section == .working)
        #expect(snapshot.agents.first?.blocker == nil)
    }
}

struct StatusOnlyRowActionTests {
    typealias S = StatusOnlyFixtures

    @Test func aWaitingDesktopRowOffersParkOnly() {
        let row = S.desktopAgent()
        #expect(RowButtons.available(for: row).map(\.button) == [.park])
        #expect(RowButtons.menuItems(for: row).filter(\.isEnabled).isEmpty)
        for button in [RowButton.answer, .review, .openTerminal, .message, .compact, .clear, .done, .closePane] {
            #expect(!RowButtons.isPressable(button, on: row), "\(button) must not be pressable")
        }
        #expect(RowButtons.isPressable(.park, on: row))
    }

    @Test func aWorkingOrParkedDesktopRowHasNoMessageOrDone() {
        #expect(RowButtons.available(for: S.desktopAgent(section: .working)).isEmpty)
        #expect(RowButtons.available(for: S.desktopAgent(section: .parked)).map(\.button) == [.unpark])
    }

    @Test func aWaitingDesktopRowIsNeedsYouButNotACornerCard() {
        let row = S.desktopAgent()
        let content = CornerTabContent.forArrivals([row], among: [row])
        #expect(content?.count == 1)
        #expect(content?.blockedCount == 0)
        #expect(content?.soleCardableAgentID == nil)
    }

    @Test func copyLeavesOutThePaneLine() {
        let text = S.desktopAgent().identityText
        #expect(!text.contains("Pane:"))
        #expect(text.contains("Session: \(S.desktopSession)"))
    }

    @Test func theSettingHidesStatusOnlyRowsOnly() {
        var settings = AgentListSettings.standard
        let herdr = AgentListFixtures.agent("h")
        #expect(settings.applying(to: [herdr, S.desktopAgent()]).count == 2)
        settings.showsClaudeOutsideHerdr = false
        #expect(settings.applying(to: [herdr, S.desktopAgent()]).map(\.id) == ["h"])
    }
}

@MainActor
struct ClaudeDesktopOpenerTests {
    @Test func theSessionLinkWinsAndTheAppIsTheFallback() {
        var calls: [String] = []
        func opener(linkOpens: Bool, appOpens: Bool = true) -> ClaudeDesktopOpener {
            ClaudeDesktopOpener(
                openURL: { calls.append("url:\($0.absoluteString)"); return linkOpens },
                activateApp: { calls.append("app:\($0)"); return appOpens }
            )
        }
        let link = URL(string: StatusOnlyFixtures.openUrl)!
        #expect(opener(linkOpens: true).openSession(link))
        #expect(calls == ["url:\(StatusOnlyFixtures.openUrl)"])
        calls = []
        #expect(opener(linkOpens: false).openSession(link))
        #expect(calls == ["url:\(StatusOnlyFixtures.openUrl)", "app:com.anthropic.claudefordesktop"])
        calls = []
        #expect(opener(linkOpens: true).openSession(nil))
        #expect(calls == ["app:com.anthropic.claudefordesktop"])
        #expect(!opener(linkOpens: false, appOpens: false).openSession(link))
    }
}

struct StatusOnlyEndedRowTests {
    /// The board keeps a status-only session's old id as an "ended" row with no pane — after it
    /// exits, and also after /clear or a resume while the SAME process still runs (new session id,
    /// same name), which would list it twice. Measured live 2026-09-26: `derived.paneId: ""`.
    @Test func panelessEndedBoardRowsAreLeftOut() throws {
        let endedTs = StatusFixtures.serverNow.timeIntervalSince1970 - 60
        func endedRow(_ rowId: String, paneId: Any?) -> [String: Any] {
            var derived: [String: Any] = ["label": "command-bar-macos-6d", "rowId": rowId, "ended": true]
            if let paneId { derived["paneId"] = paneId }
            return ["rowKind": "session", "rowId": rowId, "status": "ended", "archived": false,
                    "endedTs": endedTs, "endedNote": "ended", "derived": derived]
        }
        let snapshot = try StatusSnapshotBuilder.snapshot(
            fromJSON: StatusFixtures.data("state-healthy") { object in
                var board = object["board"] as! [String: Any]
                board["rows"] = (board["rows"] as! [Any]) + [
                    endedRow("aaaaaaaa-0000-4000-8000-000000000001", paneId: ""),
                    endedRow("aaaaaaaa-0000-4000-8000-000000000002", paneId: NSNull()),
                    endedRow("aaaaaaaa-0000-4000-8000-000000000003", paneId: nil),
                ]
                object["board"] = board
            },
            fetchedAt: StatusFixtures.serverNow
        )
        let ended = snapshot.agents(in: .ended)
        #expect(!ended.contains { $0.label == "command-bar-macos-6d" })
        #expect(ended.count == 12)   // the fixture's own ended rows, unchanged
    }
}
