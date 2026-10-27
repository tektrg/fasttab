import Foundation

// Claude account rotation (brief `.claude/briefs/claude-account-rotation.md`, slice 3). The dashboard
// owns the logic (`dashboard/server/lib/account_rotation.py`); AgentBar only shows its state and sends
// the user's two decisions: approve the paid fallback tier, or resume a walled pane on the next account.

/// `GET /api/accounts`, the parts AgentBar reads. Lenient: an odd row costs only itself.
struct DashboardAccounts: Decodable, Equatable, Sendable {
    struct Account: Decodable, Equatable, Sendable {
        let id: String
        let label: String?
        /// `login` (a Claude subscription in its own CLAUDE_CONFIG_DIR), `proxy` or `apikey`.
        var kind: String? = nil
        var tier: String? = nil
        var needsApproval: Bool? = nil
        /// Router cooldown left after a 429/529, seconds.
        var cooldownSecondsLeft: Double? = nil
        /// Unix time until which rotation treats this account as at its usage limit.
        var limitedUntil: Double? = nil
        /// Login rows only: credentials exist for its config dir; nil = unknown.
        var loggedIn: Bool? = nil

        init(id: String, label: String?, kind: String? = nil, tier: String? = nil, needsApproval: Bool? = nil,
             cooldownSecondsLeft: Double? = nil, limitedUntil: Double? = nil, loggedIn: Bool? = nil) {
            self.id = id
            self.label = label
            self.kind = kind
            self.tier = tier
            self.needsApproval = needsApproval
            self.cooldownSecondsLeft = cooldownSecondsLeft
            self.limitedUntil = limitedUntil
            self.loggedIn = loggedIn
        }

        private enum CodingKeys: String, CodingKey {
            case id, label, kind, tier, needsApproval, cooldownSecondsLeft, limitedUntil, loggedIn
        }

        /// Only `id` is required; an odd optional field reads as absent.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            label = container.lenient(.label)
            kind = container.lenient(.kind)
            tier = container.lenient(.tier)
            needsApproval = container.lenient(.needsApproval)
            cooldownSecondsLeft = container.lenient(.cooldownSecondsLeft)
            limitedUntil = container.lenient(.limitedUntil)
            loggedIn = container.lenient(.loggedIn)
        }

        var displayLabel: String { label.flatMap { $0.isEmpty ? nil : $0 } ?? id }
        var canLogIn: Bool { kind == "login" }

        /// Settings › Accounts status words, most urgent first; nil = nothing to say.
        func statusText(pendingApprovalID: String?, now: Date) -> String? {
            if pendingApprovalID == id { return "Waiting for your approval" }
            if let limitedUntil, limitedUntil > now.timeIntervalSince1970 {
                let until = Date(timeIntervalSince1970: limitedUntil).formatted(date: .omitted, time: .shortened)
                return "Limited until \(until)"
            }
            if let left = cooldownSecondsLeft, left > 0 { return "Cooling down (\(Int(left.rounded(.up)))s)" }
            switch loggedIn {
            case true?: return "Logged in"
            case false?: return "Not logged in"
            case nil: return nil
            }
        }
    }

    let accounts: [Account]
    /// The fallback tier (e.g. DeepSeek) is waiting for the user's yes; nil when nothing waits.
    let pendingApproval: PendingFallbackApproval?

    private enum CodingKeys: String, CodingKey { case accounts, pendingApproval }

    init(accounts: [Account], pendingApproval: PendingFallbackApproval?) {
        self.accounts = accounts
        self.pendingApproval = pendingApproval
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accounts = (container.lenient(.accounts) as LenientArray<Account>?)?.elements ?? []
        pendingApproval = container.lenient(.pendingApproval)
    }

    /// The name the user gave `id` in `accounts.json`, else the id itself. "default" is `~/.claude`.
    func label(for id: String) -> String {
        accounts.first { $0.id == id }?.label.flatMap { $0.isEmpty ? nil : $0 } ?? id
    }
}

/// `pendingApproval`: `{id, label, since}`.
struct PendingFallbackApproval: Decodable, Equatable, Sendable {
    let id: String
    let label: String?

    var displayLabel: String { (label?.isEmpty == false ? label : nil) ?? id }
}

/// `POST /api/accounts/approve-fallback` and `/resume` replies: `{ok: true, …}` or `{ok: false, error}`.
struct DashboardAccountActionResponse: Decodable {
    let ok: Bool?
    let error: String?
}

/// What an account action amounts to, in words on failure.
enum AccountActionOutcome: Equatable, Sendable {
    case succeeded
    case failed(String)

    /// Sends one `{ok, error}` account POST and words any failure.
    static func perform(_ request: URLRequest, transport: DashboardTransport) async -> AccountActionOutcome {
        do {
            let (body, statusCode) = try await transport.response(for: request)
            if statusCode == 404 { return .failed("This dashboard has no account rotation yet — update it.") }
            let reply = try JSONDecoder().decode(DashboardAccountActionResponse.self, from: body)
            if reply.ok == true { return .succeeded }
            return .failed(reply.error ?? "The dashboard refused (HTTP \(statusCode)).")
        } catch is DecodingError {
            return .failed("The dashboard sent an unreadable reply.")
        } catch let error as URLError where error.code == .timedOut {
            return .failed("The dashboard took too long to answer. Check the agent: it may have gone through.")
        } catch {
            return .failed("Can't reach the status dashboard.")
        }
    }
}

extension StatusSnapshot {
    /// Adds what `/api/accounts` knows: each row's account name and the pending fallback approval.
    /// A walled row always shows its account; otherwise "default" (`~/.claude`) stays untagged.
    func withAccounts(_ accounts: DashboardAccounts?) -> StatusSnapshot {
        var copy = replacingAgents(agents.map { agent in
            var agent = agent
            if let id = agent.account, agent.limitWall || id != "default" {
                agent.accountLabel = accounts?.label(for: id) ?? id
            }
            return agent
        })
        copy.pendingFallback = accounts?.pendingApproval
        return copy
    }
}
