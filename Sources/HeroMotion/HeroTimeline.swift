import Foundation

// Timing math for the onboarding heroes, shared by the Mac app
// (`Sources/FastTab/OnboardingHeroes`) and the iPhone app
// (`ios/FastTabMobile/Onboarding/Views/Heroes`). Pure Foundation, so both
// stages draw the same beats and the math is tested once (`HeroMotionTests`).

/// How an onboarding hero's clock runs. Pure, so frame timing is testable
/// without rendering; each app's hero stage feeds it the elapsed time.
public enum HeroPlayback: Equatable, Hashable, Sendable {
    /// Repeats every `period` seconds while the step is on screen.
    /// `restAt` is the frame shown with Reduce Motion (or while paused).
    case loop(period: Double, restAt: Double)
    /// Plays once over `duration` seconds, then holds its last frame.
    case once(duration: Double)

    /// Seconds into the animation to draw, `elapsed` seconds after it (re)started.
    public func frameTime(elapsed: Double) -> Double {
        let elapsed = max(elapsed, 0)
        switch self {
        case .loop(let period, _):
            return elapsed.truncatingRemainder(dividingBy: period)
        case .once(let duration):
            return min(elapsed, duration)
        }
    }

    /// The still frame: Reduce Motion, paused, or a finished one-shot.
    public var restTime: Double {
        switch self {
        case .loop(_, let restAt): return restAt
        case .once(let duration): return duration
        }
    }

    /// Seconds until a one-shot reaches its rest frame; `nil` for loops.
    public var oneShotDuration: Double? {
        if case .once(let duration) = self { return duration }
        return nil
    }
}

/// The stage's clock: when the current picture started and whether its
/// one-shot has finished. Pure, so restarts and pauses are testable.
public struct HeroClock {
    private var key: AnyHashable?
    private var startedAt: Date?
    private var isFinished = false

    public init() {}

    /// A new picture (or the step reappearing) plays from its first frame.
    public mutating func start(key: AnyHashable, at now: Date) {
        self.key = key
        startedAt = now
        isFinished = false
    }

    /// Call whenever the picture (`key`) or `canAnimate` changes. A new picture
    /// restarts the clock. A one-shot's success beat only counts once it has
    /// been seen: one that could not animate (the user was in another app when
    /// the state arrived) plays from its first frame once it can.
    /// Returns the seconds until `finish(key:)` is due, or `nil` if none is.
    public mutating func sync(key: AnyHashable, playback: HeroPlayback, canAnimate: Bool, at now: Date) -> Double? {
        let isNewPicture = self.key != key
        if isNewPicture { start(key: key, at: now) }
        guard let duration = playback.oneShotDuration, canAnimate, !isFinished else { return nil }
        if !isNewPicture { start(key: key, at: now) }
        return duration
    }

    /// A one-shot reached its last frame; ignored if the picture has since changed.
    public mutating func finish(key: AnyHashable) {
        if self.key == key { isFinished = true }
    }

    /// After a pause (Reduce Motion, background, covered) a loop picks up from
    /// the rest frame it was showing, instead of jumping to wherever its old
    /// clock had got to. One-shots keep their own clock.
    public mutating func resume(playback: HeroPlayback, at now: Date) {
        guard playback.oneShotDuration == nil, startedAt != nil else { return }
        startedAt = now.addingTimeInterval(-playback.restTime)
    }

    /// False once the picture rests for good, so the timeline stops ticking.
    public func isTicking(key: AnyHashable, canAnimate: Bool) -> Bool {
        canAnimate && !(self.key == key && isFinished)
    }

    public func frameTime(playback: HeroPlayback, key: AnyHashable, canAnimate: Bool, now: Date) -> Double {
        guard canAnimate else { return playback.restTime }
        // The state just changed and its clock starts on the next tick: show its
        // first frame, never a flash of its last.
        guard self.key == key, let startedAt else { return 0 }
        if isFinished { return playback.restTime }
        return playback.frameTime(elapsed: now.timeIntervalSince(startedAt))
    }
}

/// Beat math for hero frames: "this move starts at 0.3s and takes 0.7s".
public enum HeroCurve {
    public enum Ease: Sendable {
        case linear
        case easeInOut
        case easeOut
        /// Overshoots slightly past 1, then settles: bounces and spring slides.
        case spring
    }

    /// 0 before `start`, 1 after `start + duration`, eased in between.
    public static func progress(_ time: Double, start: Double, duration: Double, ease: Ease = .easeInOut) -> Double {
        guard duration > 0 else { return time >= start ? 1 : 0 }
        let linear = min(max((time - start) / duration, 0), 1)
        switch ease {
        case .linear:
            return linear
        case .easeInOut:
            return linear * linear * (3 - 2 * linear)
        case .easeOut:
            return 1 - pow(1 - linear, 3)
        case .spring:
            let overshoot = 1.70158
            let shifted = linear - 1
            return 1 + (overshoot + 1) * pow(shifted, 3) + overshoot * pow(shifted, 2)
        }
    }

    /// Opacity for a looping hero's moving parts: fades out over the last
    /// `fade` seconds of the loop and back in over the first `fade`, so the
    /// jump back to frame 0 never snaps. Always 1 for a one-shot.
    public static func loopFade(_ time: Double, playback: HeroPlayback, fade: Double = 0.3) -> Double {
        guard case .loop(let period, _) = playback else { return 1 }
        let fadeIn = progress(time, start: 0, duration: fade)
        let fadeOut = 1 - progress(time, start: period - fade, duration: fade)
        return min(fadeIn, fadeOut)
    }

    public static func lerp(_ from: Double, _ to: Double, _ amount: Double) -> Double {
        from + (to - from) * amount
    }
}
