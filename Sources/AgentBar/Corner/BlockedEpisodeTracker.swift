import Foundation

/// Spots agents in Needs you that have just become blocked on the user (a question or a permission
/// box, however AgentBar came to know: dashboard, blocker memory or its own pane read). Pure.
///
/// One report per agent per stay in Needs you: an agent already reported keeps quiet while it stays,
/// even if its blocker flaps, and can be reported again after it left and came back. Like
/// `NeedsYouArrivalDetector`, the first reading after a start or a dead feed is only a baseline:
/// agents already blocked then are not "new".
struct BlockedEpisodeTracker: Equatable, Sendable {
    private var announcedIDs: Set<String>?

    /// `needsYou` is nil when there is no trustworthy reading. True when an agent newly became blocked.
    mutating func observe(_ needsYou: [AgentSnapshot]?) -> Bool {
        guard let needsYou else {
            announcedIDs = nil
            return false
        }
        let blockedIDs = Set(needsYou.filter { $0.blocker != nil }.map(\.id))
        let stillPresent = Set(needsYou.map(\.id))
        let previous = announcedIDs
        announcedIDs = (previous ?? []).intersection(stillPresent).union(blockedIDs)
        guard let previous else { return false }
        return !blockedIDs.subtracting(previous).isEmpty
    }
}
