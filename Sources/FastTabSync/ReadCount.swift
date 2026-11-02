import Foundation

/// One reader session's "read it again" counter, shared by the phone and Mac readers.
///
/// A read counts when, within one session, progress reaches the finish line (99%,
/// `LinkShelves.finishedThreshold`) having **started** that session below `startsBelow`.
/// A finished article reopens parked at the end (a revisit, not counted); going back to the
/// top (below `restartsBelow`) starts the reread there. So reopening at the end or scrolling
/// around near it adds nothing, rereading from the top adds one, and a session counts at
/// most once.
public struct ReadSession: Equatable, Sendable {
    /// A session that opens at or past this is a revisit, not a reread.
    public static let startsBelow = 0.9
    /// A revisit becomes a reread once the reader is back this close to the top.
    public static let restartsBelow = 0.1

    /// True while a finish would count (false for a revisit until it goes back to the top).
    public private(set) var canCount: Bool
    private var hasCounted = false

    public init(startProgress: Double) {
        canCount = startProgress < Self.startsBelow
    }

    /// Feed every progress update; true exactly once, on the update that finishes the read.
    public mutating func record(progress: Double) -> Bool {
        if !hasCounted, progress < Self.restartsBelow { canCount = true }
        guard canCount, LinkShelves.isFinished(progress: progress) else { return false }
        canCount = false
        hasCounted = true
        return true
    }
}

/// Row/card text for read progress and read count, one wording everywhere.
public enum ReadProgressText {
    /// "Read 3×", or nil before the first counted read.
    public static func readCount(_ count: Int) -> String? {
        count > 0 ? "Read \(count)×" : nil
    }

    /// The row line: without a count, "Read" (finished) / "40% read" / nil (unstarted);
    /// with one, "100% · Read 3×" / "40% · Read 2×" / "Read 1×".
    public static func line(progress: Double, readCount count: Int) -> String? {
        let clamped = min(max(progress, 0), 1)
        let finished = LinkShelves.isFinished(progress: clamped)
        guard let countText = readCount(count) else {
            if finished { return "Read" }
            return clamped > 0.01 ? "\(Int(clamped * 100))% read" : nil
        }
        guard clamped > 0.01 else { return countText }
        return "\(finished ? 100 : Int(clamped * 100))% · \(countText)"
    }
}
