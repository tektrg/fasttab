import Foundation

// Claude account rotation (brief `.claude/briefs/claude-account-rotation.md`, slice 3). The dashboard
// owns the logic (`dashboard/server/lib/account_rotation.py`); AgentBar only shows its state and sends
// the user's two decisions: approve the paid fallback tier, or resume a walled pane on the next account.

/// `GET /api/accounts`, the parts AgentBar reads. Lenient: an odd row costs only itself.
struct DashboardAccounts: Decodable, Equatable, Sendable {
    struct Account: Decodable, Equatable, Sendable {
        let id: String
        let label: String?
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
