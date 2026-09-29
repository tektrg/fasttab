import Foundation

/// How an onboarding hero's clock runs. Pure, so frame timing is testable
/// without rendering; `OnboardingHeroStage` feeds it the elapsed time.
enum HeroPlayback: Equatable {
    /// Repeats every `period` seconds while the step is on screen.
    /// `restAt` is the frame shown with Reduce Motion (or while paused).
    case loop(period: Double, restAt: Double)
    /// Plays once over `duration` seconds, then holds its last frame.
    case once(duration: Double)

    /// Seconds into the animation to draw, `elapsed` seconds after it (re)started.
    func frameTime(elapsed: Double) -> Double {
        let elapsed = max(elapsed, 0)
        switch self {
        case .loop(let period, _):
            return elapsed.truncatingRemainder(dividingBy: period)
        case .once(let duration):
            return min(elapsed, duration)
        }
    }

    /// The still frame: Reduce Motion, paused, or a finished one-shot.
    var restTime: Double {
        switch self {
        case .loop(_, let restAt): return restAt
        case .once(let duration): return duration
        }
    }

    /// Seconds until a one-shot reaches its rest frame; `nil` for loops.
    var oneShotDuration: Double? {
        if case .once(let duration) = self { return duration }
        return nil
    }
}

/// Beat math for hero frames: "this move starts at 0.3s and takes 0.7s".
enum HeroCurve {
    enum Ease {
        case linear
        case easeInOut
        case easeOut
        /// Overshoots slightly past 1, then settles: bounces and spring slides.
        case spring
    }

    /// 0 before `start`, 1 after `start + duration`, eased in between.
    static func progress(_ time: Double, start: Double, duration: Double, ease: Ease = .easeInOut) -> Double {
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
    static func loopFade(_ time: Double, playback: HeroPlayback, fade: Double = 0.3) -> Double {
        guard case .loop(let period, _) = playback else { return 1 }
        let fadeIn = progress(time, start: 0, duration: fade)
        let fadeOut = 1 - progress(time, start: period - fade, duration: fade)
        return min(fadeIn, fadeOut)
    }

    static func lerp(_ from: Double, _ to: Double, _ amount: Double) -> Double {
        from + (to - from) * amount
    }
}
