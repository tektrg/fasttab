import Foundation

/// Spots agents that have just entered "Needs you". Pure.
///
/// It remembers the ids seen in the previous reading and reports the ones in
/// the next reading that were not there. The first reading after a start, or
/// after the feed was unavailable, is only a baseline: agents already waiting
/// when AgentBar launches (or when the feed comes back) are not "new". An
/// agent that leaves and later returns (Unpark, or worked-then-finished) is
/// new again.
struct NeedsYouArrivalDetector: Equatable, Sendable {
    private var knownIDs: Set<String>?

    /// `needsYou` is what the user sees in Needs you, or nil when there is no
    /// trustworthy reading (nothing received yet, or the feed is down).
    /// Returns the newcomers, in the order given.
    mutating func observe(_ needsYou: [AgentSnapshot]?) -> [AgentSnapshot] {
        guard let needsYou else {
            knownIDs = nil
            return []
        }
        let previous = knownIDs
        knownIDs = Set(needsYou.map(\.id))
        guard let previous else { return [] }
        return needsYou.filter { !previous.contains($0.id) }
    }
}
