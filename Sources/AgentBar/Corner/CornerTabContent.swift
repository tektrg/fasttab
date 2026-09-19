import Foundation

/// The words on the corner tab: how many agents need the user, and who
/// arrived last. Pure.
struct CornerTabContent: Equatable, Sendable {
    let count: Int
    let newestName: String

    /// "3 need you", or "1 needs you".
    var headline: String {
        count == 1 ? "1 needs you" : "\(count) need you"
    }

    /// Content for a reading with `arrivals` among `needsYou`; nil when nobody arrived.
    /// The newest arrival is the one that has been in its status for the
    /// shortest time (an unknown time ranks last); ties keep the given order.
    static func forArrivals(_ arrivals: [AgentSnapshot], among needsYou: [AgentSnapshot]) -> CornerTabContent? {
        guard let newest = arrivals.min(by: { ($0.secondsInStatus ?? .infinity) < ($1.secondsInStatus ?? .infinity) })
        else { return nil }
        return CornerTabContent(count: needsYou.count, newestName: newest.label)
    }
}
