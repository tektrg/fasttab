import Foundation

/// Pure decisions behind the reader's "phone stays cool" fixes. No UIKit, so they are
/// unit-tested headless (`ReaderPerfGatesTests`).

/// The single "reader is at the end of the article" signal. Native scroll offset and the page's
/// progress message used to compute it with different thresholds (offset ≥ max−80pt vs
/// progress ≥ 0.90) and flip-flopped. Both now feed this one tracker with the same quantity
/// (scroll progress 0…1); a small dead band stops jitter at the edge.
struct ReaderEndZone: Equatable {
    static let enter = 0.90
    static let exit = 0.88
    private(set) var isAtEnd = false

    /// New state when it changed, nil otherwise.
    mutating func update(progress: Double) -> Bool? {
        let next = isAtEnd ? progress >= Self.exit : progress >= Self.enter
        guard next != isAtEnd else { return nil }
        isAtEnd = next
        return next
    }

    /// Short content that fits the viewport counts as the end.
    mutating func contentFits() -> Bool? {
        guard !isAtEnd else { return nil }
        isAtEnd = true
        return true
    }
}

/// At most one effect per `minInterval`; the caller keeps a trailing run for a skipped one.
struct ReaderRateGate {
    let minInterval: TimeInterval
    private(set) var lastFired: Date?

    init(minInterval: TimeInterval) { self.minInterval = minInterval }

    /// Seconds to wait before firing is allowed (0 = now).
    func delay(now: Date) -> TimeInterval {
        guard let lastFired else { return 0 }
        let elapsed = now.timeIntervalSince(lastFired)
        if elapsed < 0 { return 0 }  // clock moved back: never freeze
        return max(0, minInterval - elapsed)
    }

    mutating func markFired(now: Date) { lastFired = now }
}
