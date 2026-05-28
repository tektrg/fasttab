import Foundation

/// Persisted frecency entry per `(browser, profile, normalizedURL)` key.
///
/// `count` is a decayed, weighted visit count. `cachedScore` / `cachedScoreAt`
/// memoize the most recent `Frecency.score` computation so list-sort doesn't
/// recompute `pow()` for every entry on every keystroke; callers must respect
/// `Frecency.scoreCacheTTL` and fall back to `Frecency.score(_:now:)` when stale.
struct FrecencyEntry: Codable, Equatable, Sendable {
    var count: Double
    var lastVisit: Date
    var cachedScore: Double
    var cachedScoreAt: Date
}

/// Pure functions: scoring, URL normalization, key construction, eviction.
/// No I/O. No global state. Unit-testable in isolation.
enum Frecency {
    /// Half-life for the decay curve, in days. A tab visited today has full
    /// weight; 3 days ago weights 0.5; 6 days ago 0.25; 21 days ago ~0.008.
    static let halfLifeDays: Double = 3

    /// Entries with `lastVisit` older than this many days are evicted on
    /// load/persist. Chosen so the residual score is <0.01 of a single visit.
    static let evictionMaxAgeDays: Double = 21

    /// Cached score TTL. Beyond this, `liveScore` recomputes.
    static let scoreCacheTTL: TimeInterval = 60

    /// Frecency score: `count × 2^(-Δdays / halfLifeDays)`.
    /// Δdays clamps at 0 (future timestamps treated as "now").
    static func score(_ entry: FrecencyEntry, now: Date = Date()) -> Double {
        let deltaDays = max(0, now.timeIntervalSince(entry.lastVisit) / 86_400)
        return entry.count * pow(2.0, -deltaDays / halfLifeDays)
    }

    /// Cache-aware score. Returns the persisted `cachedScore` when fresh;
    /// otherwise recomputes. Read-only — caller mutates the entry if it wants
    /// to refresh the cache (see `refreshCachedScore`).
    static func liveScore(_ entry: FrecencyEntry, now: Date = Date()) -> Double {
        if now.timeIntervalSince(entry.cachedScoreAt) < scoreCacheTTL {
            return entry.cachedScore
        }
        return score(entry, now: now)
    }

    /// Refreshes the in-place cache without changing `count` / `lastVisit`.
    /// Cheap and idempotent.
    static func refreshCachedScore(_ entry: inout FrecencyEntry, now: Date = Date()) {
        let s = score(entry, now: now)
        entry.cachedScore = s
        entry.cachedScoreAt = now
    }

    /// Apply a visit: decays the existing count to `now`, adds `weight`, and
    /// resets `lastVisit`/cache to `now`. Equivalent to "exponential moving
    /// counter" — keeps the count meaningful across long gaps.
    static func applyVisit(_ entry: inout FrecencyEntry, weight: Double = 1.0, now: Date = Date()) {
        let decayed = score(entry, now: now)
        entry.count = decayed + weight
        entry.lastVisit = now
        entry.cachedScore = entry.count
        entry.cachedScoreAt = now
    }

    /// Factory for a brand-new entry.
    static func newEntry(weight: Double = 1.0, now: Date = Date()) -> FrecencyEntry {
        FrecencyEntry(count: weight, lastVisit: now, cachedScore: weight, cachedScoreAt: now)
    }

    /// Normalize a URL for stable identity across navigations and minor variants.
    /// - lowercase scheme + host
    /// - keep path (sans trailing slash, except root `/`)
    /// - strip query and fragment
    /// Returns the original string if URL parsing fails.
    static func normalizeURL(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let comps = URLComponents(string: trimmed),
              let scheme = comps.scheme?.lowercased(),
              !scheme.isEmpty else {
            return trimmed
        }
        let host = (comps.host ?? "").lowercased()
        var path = comps.path
        if path.count > 1, path.hasSuffix("/") { path.removeLast() }
        if host.isEmpty, path.isEmpty {
            return trimmed
        }
        return "\(scheme)://\(host)\(path)"
    }

    /// `browser|profile|normalizedURL`. When profile is nil/empty, collapses
    /// to a sentinel `*` so unknown-profile entries share a bucket per
    /// (browser, URL) but stay separate from known-profile entries.
    static func key(browser: String, profile: String?, url: String) -> String {
        let prof: String = {
            if let p = profile?.trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty {
                return p
            }
            return "*"
        }()
        return "\(browser)|\(prof)|\(normalizeURL(url))"
    }

    /// Returns `true` if the entry's last visit is older than the eviction
    /// threshold. Used to bound store size during load/persist.
    static func shouldEvict(_ entry: FrecencyEntry, now: Date = Date()) -> Bool {
        let ageDays = now.timeIntervalSince(entry.lastVisit) / 86_400
        return ageDays > evictionMaxAgeDays
    }

    /// Best-effort profile parse from a Chromium-style window title.
    /// Chrome window titles end with " - <ProfileName>" when multiple profiles
    /// exist. Returns nil when the pattern doesn't match — caller falls back
    /// to the collapsed `(browser, URL)` key.
    static func profileFromWindowTitle(_ windowTitle: String?) -> String? {
        guard let raw = windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        guard let range = raw.range(of: " - ", options: .backwards) else { return nil }
        let candidate = raw[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        // Skip suffixes that are obviously not a profile name (e.g. browser
        // app name itself, or a page title fragment with no profile semantics).
        guard !candidate.isEmpty, candidate.count <= 64 else { return nil }
        let lower = candidate.lowercased()
        let appSuffixes: Set<String> = [
            "google chrome",
            "chrome",
            "microsoft edge",
            "edge",
            "brave",
            "arc",
            "safari"
        ]
        if appSuffixes.contains(lower) { return nil }
        return candidate
    }
}
