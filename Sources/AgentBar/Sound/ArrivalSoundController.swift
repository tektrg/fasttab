import Foundation

/// Plays the alert for agents arriving in Needs you: feeds each reading to the pure
/// `ArrivalSoundPlanner`, schedules a re-check when an arrival is being held, and plays the
/// chosen cue with the sound the user picked. Plays whether or not the panel or corner tab is
/// showing; nothing plays when sounds are off (the planner still runs, so switching sounds
/// back on never replays old arrivals).
@MainActor
final class ArrivalSoundController {
    /// Runs the action once after the delay (a real timer in the app, a manual trigger in tests).
    typealias Schedule = @MainActor (_ delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> Void

    private let settings: () -> SoundSettings
    private let player: SoundPlayer
    private let now: () -> Date
    private let schedule: Schedule
    private var planner = ArrivalSoundPlanner()
    private var lastNeedsYou: [AgentSnapshot] = []
    private var scheduledFor: Date?

    init(
        settings: @escaping () -> SoundSettings,
        player: SoundPlayer = SystemSoundPlayer(),
        now: @escaping () -> Date = { Date() },
        schedule: @escaping Schedule = ArrivalSoundController.realSchedule
    ) {
        self.settings = settings
        self.player = player
        self.now = now
        self.schedule = schedule
    }

    /// Every reading of Needs you, as `AgentPanelModel` sees it. `needsYou` is empty when there is no trustworthy reading.
    func observe(arrivals: [AgentSnapshot], needsYou: [AgentSnapshot]) {
        lastNeedsYou = needsYou
        decide(arrivals: arrivals)
        scheduleRecheckIfHolding()
    }

    private func decide(arrivals: [AgentSnapshot]) {
        guard let cue = planner.observe(arrivals: arrivals, needsYou: lastNeedsYou, now: now()) else { return }
        let current = settings()
        guard current.playsSounds else { return }
        player.play(current.choice(for: cue))
    }

    private func scheduleRecheckIfHolding() {
        guard let deadline = planner.nextDeadline, deadline > (scheduledFor ?? .distantPast) else { return }
        scheduledFor = deadline
        schedule(max(0, deadline.timeIntervalSince(now()))) { [weak self] in
            guard let self else { return }
            scheduledFor = nil
            decide(arrivals: [])
            scheduleRecheckIfHolding()
        }
    }

    static func realSchedule(after delay: TimeInterval, action: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            action()
        }
    }
}
