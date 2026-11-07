import Foundation

/// Today's reading against the daily word goal (More → Reading goal), drawn by the reader page
/// as a second bar under the article's progress bar. Same words the Reading ring widget counts.
///
/// Sent to the page once per article; the page grows the bar live as the reader scrolls past
/// `highWater` (`ftSetDailyGoal` in reader_template.html mirrors `fraction(sessionProgress:)`).
public struct ReaderDailyGoal: Equatable, Encodable, Sendable {
    /// Words already in the reading log for today.
    let wordsToday: Double
    /// Words in this article; 0 when it does not count toward stats.
    let articleWords: Int
    /// How far into this article the log already counts. Only ground past it is new today.
    let highWater: Double
    let goal: Int

    /// Words read today once the reader has reached `sessionProgress` (furthest this session).
    func words(sessionProgress: Double) -> Double {
        wordsToday + Double(articleWords) * max(0, min(1, sessionProgress) - highWater)
    }

    /// 0...1, the drawn bar.
    func fraction(sessionProgress: Double) -> Double {
        goal > 0 ? min(1, words(sessionProgress: sessionProgress) / Double(goal)) : 0
    }
}
