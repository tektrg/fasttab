import Foundation

/// Persisted frecency entry for one ranked item.
///
/// `count` is a decayed, weighted visit count. `cachedScore` / `cachedScoreAt`
/// memoize the most recent `Frecency.score` computation so list-sort doesn't
/// recompute `pow()` for every entry on every keystroke; callers must respect
/// `Frecency.scoreCacheTTL` and fall back to `Frecency.score(_:now:)` when stale.
public struct FrecencyEntry: Codable, Equatable, Sendable {
    public var count: Double
    public var lastVisit: Date
    public var cachedScore: Double
    public var cachedScoreAt: Date

    public init(count: Double, lastVisit: Date, cachedScore: Double, cachedScoreAt: Date) {
        self.count = count
        self.lastVisit = lastVisit
        self.cachedScore = cachedScore
        self.cachedScoreAt = cachedScoreAt
    }
}

/// Pure functions: scoring, decay, eviction. How entries are keyed is up to the
/// app (FastTab keys them per browser/profile/URL in `Frecency+Browser.swift`).
/// No I/O. No global state. Unit-testable in isolation.
public enum Frecency {
    /// Half-life for the decay curve, in days. An item visited today has full
    /// weight; 3 days ago weights 0.5; 6 days ago 0.25; 21 days ago ~0.008.
    public static let halfLifeDays: Double = 3

    /// Entries with `lastVisit` older than this many days are evicted on
    /// load/persist. Chosen so the residual score is <0.01 of a single visit.
    public static let evictionMaxAgeDays: Double = 21

    /// Cached score TTL. Beyond this, `liveScore` recomputes.
    public static let scoreCacheTTL: TimeInterval = 60

    /// Frecency score: `count × 2^(-Δdays / halfLifeDays)`.
    /// Δdays clamps at 0 (future timestamps treated as "now").
    public static func score(_ entry: FrecencyEntry, now: Date = Date()) -> Double {
        let deltaDays = max(0, now.timeIntervalSince(entry.lastVisit) / 86_400)
        return entry.count * pow(2.0, -deltaDays / halfLifeDays)
    }

    /// Cache-aware score. Returns the persisted `cachedScore` when fresh;
    /// otherwise recomputes. Read-only — caller mutates the entry if it wants
    /// to refresh the cache (see `refreshCachedScore`).
    public static func liveScore(_ entry: FrecencyEntry, now: Date = Date()) -> Double {
        if now.timeIntervalSince(entry.cachedScoreAt) < scoreCacheTTL {
            return entry.cachedScore
        }
        return score(entry, now: now)
    }

    /// Refreshes the in-place cache without changing `count` / `lastVisit`.
    /// Cheap and idempotent.
    public static func refreshCachedScore(_ entry: inout FrecencyEntry, now: Date = Date()) {
        let s = score(entry, now: now)
        entry.cachedScore = s
        entry.cachedScoreAt = now
    }

    /// Apply a visit: decays the existing count to `now`, adds `weight`, and
    /// resets `lastVisit`/cache to `now`. Equivalent to "exponential moving
    /// counter" — keeps the count meaningful across long gaps.
    public static func applyVisit(_ entry: inout FrecencyEntry, weight: Double = 1.0, now: Date = Date()) {
        let decayed = score(entry, now: now)
        entry.count = decayed + weight
        entry.lastVisit = now
        entry.cachedScore = entry.count
        entry.cachedScoreAt = now
    }

    /// Factory for a brand-new entry.
    public static func newEntry(weight: Double = 1.0, now: Date = Date()) -> FrecencyEntry {
        FrecencyEntry(count: weight, lastVisit: now, cachedScore: weight, cachedScoreAt: now)
    }

    /// Returns `true` if the entry's last visit is older than the eviction
    /// threshold. Used to bound store size during load/persist.
    public static func shouldEvict(_ entry: FrecencyEntry, now: Date = Date()) -> Bool {
        let ageDays = now.timeIntervalSince(entry.lastVisit) / 86_400
        return ageDays > evictionMaxAgeDays
    }
}
