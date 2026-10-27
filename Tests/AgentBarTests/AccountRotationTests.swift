import Foundation
import Testing
@testable import AgentBar

struct AccountRotationTests {
    /// The healthy fixture with `limitWall` / `account` set on the agent labelled `label`.
    private func snapshot(label: String, fields: [String: Any]) throws -> StatusSnapshot {
        let json = StatusFixtures.data("state-healthy") { root in
            var computed = root["computed"] as! [String: Any]
            computed["agents"] = (computed["agents"] as! [[String: Any]]).map { agent in
                guard agent["label"] as? String == label else { return agent }
                return agent.merging(fields) { _, new in new }
            }
            root["computed"] = computed
        }
        return try StatusSnapshotBuilder.snapshot(fromJSON: json, fetchedAt: StatusFixtures.serverNow)
    }

    @Test func limitWallAndAccountDecodeOntoTheRow() throws {
        let snapshot = try snapshot(label: "agent-four", fields: ["limitWall": true, "account": "acct-b"])
        let agent = try #require(snapshot.agent(labelled: "agent-four"))
        #expect(agent.limitWall)
        #expect(agent.account == "acct-b")
    }

    @Test func absentOrOddFieldsReadAsNoWallAndUnknownAccount() throws {
        let plain = try #require(try StatusFixtures.snapshot("state-healthy").agent(labelled: "agent-four"))
        #expect(!plain.limitWall)
        #expect(plain.account == nil)
        let odd = try #require(try snapshot(label: "agent-four", fields: ["limitWall": "yes", "account": NSNull()]).agent(labelled: "agent-four"))
        #expect(!odd.limitWall)
        #expect(odd.account == nil)
    }

    @Test func accountsReplyDecodesLabelsAndPendingApproval() throws {
        let json = #"{"ok":true,"accounts":[{"id":"acct-b","label":"Work Max","kind":"login","tier":"primary"},{"id":"deepseek","label":"DeepSeek","needsApproval":true},"junk"],"autoResume":true,"routerReachable":true,"pendingApproval":{"id":"deepseek","label":"DeepSeek","since":1789744000}}"#
        let accounts = try JSONDecoder().decode(DashboardAccounts.self, from: Data(json.utf8))
        #expect(accounts.label(for: "acct-b") == "Work Max")
        #expect(accounts.label(for: "unknown") == "unknown")
        #expect(accounts.pendingApproval == PendingFallbackApproval(id: "deepseek", label: "DeepSeek"))
        let none = try JSONDecoder().decode(DashboardAccounts.self, from: Data(#"{"ok":true,"accounts":[],"pendingApproval":null}"#.utf8))
        #expect(none.pendingApproval == nil)
    }

    @Test func withAccountsLabelsNonDefaultAndWalledRowsAndCarriesThePrompt() throws {
        let base = try snapshot(label: "agent-four", fields: ["limitWall": true, "account": "default"])
        let accounts = DashboardAccounts(
            accounts: [.init(id: "default", label: "Personal")],
            pendingApproval: PendingFallbackApproval(id: "deepseek", label: "DeepSeek")
        )
        let merged = base.withAccounts(accounts)
        #expect(merged.agent(labelled: "agent-four")?.accountLabel == "Personal")   // walled: always named
        #expect(merged.pendingFallback?.displayLabel == "DeepSeek")
        #expect(merged.replacingAgents(merged.agents).pendingFallback != nil)
        let calm = try snapshot(label: "agent-four", fields: ["account": "default"]).withAccounts(accounts)
        #expect(calm.agent(labelled: "agent-four")?.accountLabel == nil)          // default, not walled: no tag
    }

    @Test func resumeIsOfferedOnlyOnAWalledHerdrPane() throws {
        let walled = try #require(try snapshot(label: "agent-four", fields: ["limitWall": true]).agent(labelled: "agent-four"))
        #expect(RowButtons.menuItems(for: walled).contains { $0.button == .resumeOnNextAccount })
        #expect(RowButtons.available(for: walled).contains { $0.button == .moreActions })
        #expect(RowButtons.isPressable(.resumeOnNextAccount, on: walled))
        let calm = try #require(try StatusFixtures.snapshot("state-healthy").agent(labelled: "agent-four"))
        #expect(!RowButtons.menuItems(for: calm).contains { $0.button == .resumeOnNextAccount })
        #expect(RowActionMachine.plan(pressing: .resumeOnNextAccount, current: nil) == .resumeOnNextAccount)
    }

    @Test func requestsIdentifyAgentBarAndCarryTheirBody() throws {
        let endpoint = DashboardEndpoint(baseURL: URL(string: "http://127.0.0.1:4711")!)
        let approve = endpoint.approveFallbackRequest(id: "deepseek")
        #expect(approve.url?.path == "/api/accounts/approve-fallback")
        #expect(approve.httpMethod == "POST")
        #expect(approve.value(forHTTPHeaderField: DashboardEndpoint.clientHeaderName) == "1")
        #expect(try JSONSerialization.jsonObject(with: approve.httpBody!) as? [String: String] == ["id": "deepseek"])
        let resume = endpoint.accountResumeRequest(paneId: "p1")
        #expect(resume.url?.path == "/api/accounts/resume")
        #expect(try JSONSerialization.jsonObject(with: resume.httpBody!) as? [String: String] == ["paneId": "p1"])
        #expect(endpoint.accountsRequest.value(forHTTPHeaderField: DashboardEndpoint.clientHeaderName) == "1")
    }
}
