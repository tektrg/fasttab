import Foundation

/// The daily word goal that closes the Reading ring widget. Set in More → Reading goal.
enum ReadingGoal {
    static let defaultsKey = "FastTabMobile.readingDailyWordGoal"
    /// About 12 minutes of reading at 250 words a minute.
    static let defaultDailyWords = 3_000
    static let range = 500...20_000
    static let step = 500

    static var dailyWords: Int {
        let stored = UserDefaults.standard.integer(forKey: defaultsKey)
        return range.contains(stored) ? stored : defaultDailyWords
    }
}
