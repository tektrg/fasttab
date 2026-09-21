import Foundation

/// The words on the corner tab: how many agents need the user, and who
/// arrived last (or that one is waiting for an answer or approval); or, when nobody does,
/// a neutral line. Pure.
struct CornerTabContent: Equatable, Sendable {
    let count: Int
    let newestName: String
    /// How many of them are blocked on the user: a question to answer or a permission box to review.
    /// While any is, the tab stays until the user deals with it.
    var blockedCount = 0
    /// The sole blocked agent's id, when `blockedCount == 1` AND its blocker is one AgentBar can
    /// render as a full card (a question or a reviewable permission/plan box) — nil for a lone
    /// `questionLoading`/`questionNotAnswerable`/plain `permission` blocker, which has no card to
    /// show, or when more than one agent is blocked (the corner falls back to the plain pill then).
    var soleCardableAgentID: String?

    /// What the tab says when nothing needs the user (or the feed is down).
    static let nothingNeedsYou = CornerTabContent(count: 0, newestName: "")

    /// "3 need you", "1 needs you", or "Nothing needs you".
    var headline: String {
        switch count {
        case 0: "Nothing needs you"
        case 1: "1 needs you"
        default: "\(count) need you"
        }
    }

    /// The grey text after the headline: the newest arrival, or the app's name when there is none.
    var detail: String {
        if blockedCount > 0 { return "waiting for your answer" }
        return newestName.isEmpty ? "AgentBar" : newestName
    }

    /// What the tab shows when the pointer rests in the corner: the current Needs-you agents
    /// (nil = no trustworthy reading), the newest of them named.
    static func summary(of needsYou: [AgentSnapshot]?) -> CornerTabContent {
        guard let needsYou, !needsYou.isEmpty else { return .nothingNeedsYou }
        return forArrivals(needsYou, among: needsYou) ?? .nothingNeedsYou
    }

    /// Content for a reading with `arrivals` among `needsYou`; nil when nobody arrived.
    /// The newest arrival is the one that has been in its status for the
    /// shortest time (an unknown time ranks last); ties keep the given order.
    static func forArrivals(_ arrivals: [AgentSnapshot], among needsYou: [AgentSnapshot]) -> CornerTabContent? {
        guard let newest = arrivals.min(by: { ($0.secondsInStatus ?? .infinity) < ($1.secondsInStatus ?? .infinity) })
        else { return nil }
        let blocked = needsYou.filter { $0.blocker != nil }
        return CornerTabContent(
            count: needsYou.count, newestName: newest.label, blockedCount: blocked.count,
            soleCardableAgentID: soleCardableAgentID(among: blocked)
        )
    }

    /// `blocked`'s one agent, when it is exactly one and its blocker is answerable/reviewable here.
    private static func soleCardableAgentID(among blocked: [AgentSnapshot]) -> String? {
        guard blocked.count == 1, let only = blocked.first else { return nil }
        switch only.blockedOnYou {
        case .question?, .permissionReview?: return only.id
        case .questionLoading?, .questionNotAnswerable?, .permission?, nil: return nil
        }
    }
}
