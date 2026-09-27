import Foundation

/// How far into each article the reader has ever scrolled (its "high water"), and whether it was
/// finished. Separate from `ReaderReadingProgress`, which stores where the reader *is* (it moves
/// back when they scroll up); stats only ever count ground covered for the first time.
///
/// Pure value: `ReadingStatsRecorder` owns persistence and turns outcomes into metric events.
struct ReadingProgressLedger: Codable, Equatable {
    /// Scrolling this far counts the article as read to the end.
    static let finishedThreshold = 0.9
    /// Smallest new ground reported between flushes, so slow scrolling writes a handful of log
    /// lines per article rather than one per pause.
    static let minimumReportedStep = 0.05
    /// Articles remembered; the least recently touched are forgotten past this.
    static let maxEntries = 2_000

    struct Entry: Codable, Equatable {
        var highWater: Double
        var isFinished: Bool
        var updatedAt: Date
    }

    /// What one progress update means for stats.
    struct Outcome: Equatable {
        /// Share of the article (0...1) read for the first time.
        var newlyReadFraction: Double
        /// True exactly once per article: the update that crossed `finishedThreshold`.
        var didFinish: Bool

        static let nothing = Outcome(newlyReadFraction: 0, didFinish: false)
    }

    private(set) var entries: [String: Entry] = [:]

    /// Starts an article at the progress it already had before stats existed, so reopening an
    /// old half-read article does not count its first half as read today.
    mutating func seedIfUnknown(articleKey: String, progress: Double, now: Date) {
        guard entries[articleKey] == nil else { return }
        let clamped = Self.clamped(progress)
        entries[articleKey] = Entry(highWater: clamped, isFinished: clamped >= Self.finishedThreshold, updatedAt: now)
        evictIfNeeded()
    }

    /// Moves the high water up to `progress` if that is new ground. Scrolling back never
    /// subtracts. Without `isFlush`, gains below `minimumReportedStep` wait for a later update.
    mutating func advance(articleKey: String, to progress: Double, isFlush: Bool, now: Date) -> Outcome {
        let clamped = Self.clamped(progress)
        var entry = entries[articleKey] ?? Entry(highWater: 0, isFinished: false, updatedAt: now)
        let gain = clamped - entry.highWater
        let didFinish = !entry.isFinished && clamped >= Self.finishedThreshold
        guard gain > 0 else { return .nothing }
        guard isFlush || didFinish || gain >= Self.minimumReportedStep else { return .nothing }

        entry.highWater = clamped
        entry.isFinished = entry.isFinished || didFinish
        entry.updatedAt = now
        entries[articleKey] = entry
        evictIfNeeded()
        return Outcome(newlyReadFraction: gain, didFinish: didFinish)
    }

    private mutating func evictIfNeeded() {
        guard entries.count > Self.maxEntries else { return }
        let oldestKeys = entries.sorted { $0.value.updatedAt < $1.value.updatedAt }
            .prefix(entries.count - Self.maxEntries)
            .map(\.key)
        oldestKeys.forEach { entries.removeValue(forKey: $0) }
    }

    private static func clamped(_ progress: Double) -> Double {
        progress.isFinite ? min(1, max(0, progress)) : 0
    }
}
