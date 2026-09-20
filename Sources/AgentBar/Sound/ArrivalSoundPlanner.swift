import Foundation

/// Decides which alert an agent arriving in Needs you deserves. Pure.
///
/// The dashboard's "blocked" classification can arrive ~15s after the row does, and AgentBar's own
/// pane read (`BlockerProbe`) a few seconds after that, so an arrival that is not known to be
/// blocked yet must not be called "done" straight away. Such an arrival is held for
/// `holdSeconds`: if a question or permission box shows up meanwhile it plays `.needsAnswer`,
/// otherwise `.agentDone` when the hold ends. An agent that leaves Needs you while held plays nothing.
///
/// One decision per reading: at most one cue, and if both kinds are due at once the answer alert wins.
struct ArrivalSoundPlanner: Equatable, Sendable {
    /// Longer than the probe's pane read (~2.5s), short enough to still feel immediate.
    static let holdSeconds: TimeInterval = 4

    /// Arrived, not yet known to be blocked: id -> when it arrived.
    private var undecided: [String: Date] = [:]

    /// When the oldest undecided arrival must be settled, or nil when none is waiting.
    var nextDeadline: Date? {
        undecided.values.min().map { $0.addingTimeInterval(Self.holdSeconds) }
    }

    /// `arrivals` are the agents that just entered Needs you (may be empty); `needsYou` is everyone
    /// in Needs you now, with their blockers as the panel shows them. Returns the cue to play, if any.
    mutating func observe(arrivals: [AgentSnapshot], needsYou: [AgentSnapshot], now: Date) -> SoundCue? {
        let present = Dictionary(needsYou.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        undecided = undecided.filter { present[$0.key] != nil }
        for arrival in arrivals { undecided[arrival.id] = now }

        var needsAnswer = false
        var agentDone = false
        for (id, arrivedAt) in undecided {
            if present[id]?.blocker != nil {
                needsAnswer = true
                undecided[id] = nil
            } else if now.timeIntervalSince(arrivedAt) >= Self.holdSeconds {
                agentDone = true
                undecided[id] = nil
            }
        }
        if needsAnswer { return .needsAnswer }
        return agentDone ? .agentDone : nil
    }
}
