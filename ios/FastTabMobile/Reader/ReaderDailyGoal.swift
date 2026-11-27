import Foundation

/// Today's reading against the daily word goal (More → Reading goal), drawn as the inner ring of the
/// reader's bottom-panel rings (`ReaderRingsView`). Same words the Reading ring widget counts.
///
/// Loaded once per article; the ring grows as the reader scrolls past `highWater`.
public struct ReaderDailyGoal: Equatable, Encodable, Sendable {
    /// Words already in the reading log for today.
    let wordsToday: Double
    /// Words in this article; 0 when it does not count toward stats.
    let articleWords: Int
    /// How far into this article the log already counts. Only ground past it is new today.
    let highWater: Double
    let goal: Int
    /// Words in the log since the start of this week (includes today).
    var wordsThisWeek: Double = 0

    /// Words read today once the reader has reached `sessionProgress` (furthest this session).
    func words(sessionProgress: Double) -> Double {
        wordsToday + Double(articleWords) * max(0, min(1, sessionProgress) - highWater)
    }

    /// 0...1, the drawn bar.
    func fraction(sessionProgress: Double) -> Double {
        goal > 0 ? min(1, words(sessionProgress: sessionProgress) / Double(goal)) : 0
    }

    /// Words read this week once the reader has reached `sessionProgress`.
    func weekWords(sessionProgress: Double) -> Double {
        wordsThisWeek + Double(articleWords) * max(0, min(1, sessionProgress) - highWater)
    }

    /// 0...1 against 7 × the daily goal; the app has no separate weekly goal.
    func weekFraction(sessionProgress: Double) -> Double {
        guard goal > 0 else { return 0 }
        let gain = Double(articleWords) * max(0, min(1, sessionProgress) - highWater)
        return min(1, (wordsThisWeek + gain) / Double(goal * 7))
    }
}
