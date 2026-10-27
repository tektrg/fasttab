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

    @Test func accountRowsDecodeSettingsFieldsLeniently() throws {
        let json = #"{"accounts":[{"id":"sub","label":"Sub","kind":"login","tier":"claude","loggedIn":true,"cooldownSecondsLeft":0,"limitedUntil":null},{"id":"odd","kind":5,"loggedIn":"yes"}]}"#
        let accounts = try JSONDecoder().decode(DashboardAccounts.self, from: Data(json.utf8)).accounts
        #expect(accounts.count == 2)
        #expect(accounts[0].canLogIn && accounts[0].loggedIn == true && accounts[0].tier == "claude")
        #expect(accounts[1].kind == nil && accounts[1].loggedIn == nil && !accounts[1].canLogIn)
        #expect(accounts[1].displayLabel == "odd")
    }

    @Test func accountStatusTextPicksTheMostUrgent() {
        let now = Date(timeIntervalSince1970: 1_000)
        let row = DashboardAccounts.Account(id: "a", label: nil, kind: "login", cooldownSecondsLeft: 30,
                                            limitedUntil: 2_000, loggedIn: true)
        #expect(row.statusText(pendingApprovalID: "a", now: now) == "Waiting for your approval")
        #expect(row.statusText(pendingApprovalID: nil, now: now)?.hasPrefix("Limited until") == true)
        let cooling = DashboardAccounts.Account(id: "a", label: nil, cooldownSecondsLeft: 29.2, limitedUntil: 500)
        #expect(cooling.statusText(pendingApprovalID: nil, now: now) == "Cooling down (30s)")
        #expect(DashboardAccounts.Account(id: "a", label: nil, loggedIn: false).statusText(pendingApprovalID: nil, now: now) == "Not logged in")
        #expect(DashboardAccounts.Account(id: "a", label: nil).statusText(pendingApprovalID: nil, now: now) == nil)
    }

    @Test func loginRequestPostsTheIdAndOutcomeCarriesTheError() async throws {
        let endpoint = DashboardEndpoint(baseURL: URL(string: "http://127.0.0.1:4711")!)
        let request = endpoint.accountLoginRequest(id: "sub")
        #expect(request.url?.path == "/api/accounts/login")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: DashboardEndpoint.clientHeaderName) == "1")
        #expect(try JSONSerialization.jsonObject(with: request.httpBody!) as? [String: String] == ["id": "sub"])
        let ok = ScriptedDashboardTransport { _ in .body(Data(#"{"ok":true,"tab":"t1"}"#.utf8)) }
        #expect(await AccountActionOutcome.perform(request, transport: ok) == .succeeded)
        let refused = ScriptedDashboardTransport { _ in .body(Data(#"{"ok":false,"error":"unknown account 'x'"}"#.utf8)) }
        #expect(await AccountActionOutcome.perform(request, transport: refused) == .failed("unknown account 'x'"))
        let down = ScriptedDashboardTransport { _ in .fail }
        #expect(await AccountActionOutcome.perform(request, transport: down) == .failed("Can't reach the status dashboard."))
    }

    @Test @MainActor func settingsModelLoadsAccountsAndRecordsLoginOutcome() async {
        let transport = ScriptedDashboardTransport { request in
            request.url?.path == "/api/accounts"
                ? .body(Data(#"{"accounts":[{"id":"sub","kind":"login","loggedIn":false}],"pendingApproval":null}"#.utf8))
                : .body(Data(#"{"ok":false,"error":"herdr: down"}"#.utf8))
        }
        let model = AccountsSettingsModel(endpoint: { DashboardEndpoint(baseURL: URL(string: "http://127.0.0.1:4711")!) },
                                          transport: transport)
        await model.reload()
        #expect(model.accounts?.accounts.map(\.id) == ["sub"])
        #expect(model.loadError == nil)
        await model.logIn("sub")
        #expect(model.loginResults["sub"] == .failed("herdr: down"))
        #expect(model.loggingIn.isEmpty)
    }
}

struct AccountEditRequestTests {
    private let endpoint = DashboardEndpoint(baseURL: URL(string: "http://127.0.0.1:4711")!)
    private let secret = "sk-SENTINEL-0042"

    private func body(_ request: URLRequest) throws -> [String: String] {
        try #require(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: String])
    }

    @Test func addAPICarriesTheTokenAndTier() throws {
        let form = NewAPIAccount(label: " DeepSeek ", baseURL: "https://api.deepseek.com", token: secret,
                                 model: "", isFallback: true)
        let request = endpoint.addAPIAccountRequest(form)
        #expect(request.url?.path == "/api/accounts/add-api")
        #expect(request.httpMethod == "POST")
        #expect(try body(request) == ["label": "DeepSeek", "baseUrl": "https://api.deepseek.com",
                                      "token": secret, "tier": "fallback"])
        let claude = NewAPIAccount(label: "A", baseURL: "https://x", token: "t", model: "m", isFallback: false)
        #expect(try body(endpoint.addAPIAccountRequest(claude))["tier"] == "claude")
        #expect(try body(endpoint.addAPIAccountRequest(claude))["model"] == "m")
    }

    @Test func onlyAddAPICarriesAToken() throws {
        let other = [endpoint.addSubscriptionAccountRequest(label: "Personal"), endpoint.removeAccountRequest(id: "x")]
        #expect(try body(other[0]) == ["label": "Personal"])
        #expect(try body(other[1]) == ["id": "x"])
        for request in other {
            #expect(try body(request)["token"] == nil)
            #expect(request.url?.query == nil)
        }
        let api = endpoint.addAPIAccountRequest(NewAPIAccount(label: "A", baseURL: "https://x", token: secret))
        #expect(!(api.url?.absoluteString.contains(secret) ?? true))
        #expect(api.allHTTPHeaderFields?.values.contains { $0.contains(secret) } == false)
    }

    @Test func formNeedsNameURLAndKey() {
        #expect(!NewAPIAccount(label: "A", baseURL: "https://x", token: " ").isComplete)
        #expect(NewAPIAccount(label: "A", baseURL: "https://x", token: "k").isComplete)
    }
}
