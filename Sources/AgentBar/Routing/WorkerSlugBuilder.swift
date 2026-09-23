import Foundation

/// Derives a short, dashboard-safe slug for a brand-new AptusFit worker from the drafted message
/// text — client-side and deterministic (never a second Jev call): OpenRouter's Decisions API has
/// no free-text/generate answer type, only `choice` (against a closed candidate list), `noul`
/// (boolean) and `score` — confirmed against OpenRouter's own docs 2026-09-22, so there is nothing
/// to ask Jev for a slug through. Pure aside from `randomSuffix`, a test seam.
///
/// **Known v1 gap** (flagged, not solved here): this never checks the slug against AptusFit's
/// actual existing worktree/slug list — no endpoint exposes it — so a suffix collision, while very
/// unlikely (4 random base36 characters = 1,679,616 combinations), is not impossible.
enum WorkerSlugBuilder {
    /// Mirrors AptusFit's `chief_dashboard_worker.py` `_SLUG_RE` exactly.
    static let slugPattern = "^[a-z0-9][a-z0-9._-]*$"

    private static let maxWordsInBase = 6
    private static let maxBaseLength = 40
    private static let suffixLength = 4
    private static let suffixAlphabet = Array("0123456789abcdefghijklmnopqrstuvwxyz")

    /// A kebab-case slug from `text`'s first few ASCII alphanumeric words, plus a random suffix so
    /// two drafts that start the same way don't collide. Always matches `slugPattern`.
    static func makeSlug(from text: String, randomSuffix: () -> String = { WorkerSlugBuilder.randomBase36() }) -> String {
        let base = kebabBase(from: text)
        let suffix = randomSuffix()
        let candidate = base.isEmpty ? "worker-\(suffix)" : "\(base)-\(suffix)"
        return isValid(candidate) ? candidate : "worker-\(suffix)"
    }

    /// Whether `slug` matches AptusFit's own shape — checked here too so a bad slug is refused
    /// before it ever reaches `/api/worker`.
    static func isValid(_ slug: String) -> Bool {
        guard let first = slug.unicodeScalars.first, isLowerAlnum(first) else { return false }
        return slug.unicodeScalars.allSatisfy { isLowerAlnum($0) || $0 == "." || $0 == "_" || $0 == "-" }
    }

    private static func isLowerAlnum(_ scalar: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar)
    }

    /// Lowercases `text`, keeps only ASCII letters/digits as word characters (anything else,
    /// including punctuation and non-ASCII scripts/emoji, is a separator), takes the first few
    /// words, and joins them with hyphens. Empty for text with no ASCII alphanumeric content at
    /// all (fully non-Latin or emoji-only text) — `makeSlug` falls back to a plain "worker-" slug.
    private static func kebabBase(from text: String) -> String {
        var words: [String] = []
        var current = ""
        for scalar in text.lowercased().unicodeScalars {
            if isLowerAlnum(scalar) {
                current.unicodeScalars.append(scalar)
            } else if !current.isEmpty {
                words.append(current)
                current = ""
                if words.count == maxWordsInBase { break }
            }
        }
        if words.count < maxWordsInBase, !current.isEmpty { words.append(current) }
        return String(words.joined(separator: "-").prefix(maxBaseLength))
    }

    private static func randomBase36() -> String {
        String((0..<suffixLength).compactMap { _ in suffixAlphabet.randomElement() })
    }
}
