import CommandBarKit
import Foundation

/// App-side search helpers built on the kit's folding (`foldForMatching`,
/// `searchWords(in:)`, `foldedKeys`): URL match keys, the history SQL predicate,
/// and history page identity.
///
/// Three consumers, all of which must agree or search feels inconsistent
/// depending on where a result came from:
///   1. `BrowserSearchResult.matches(query:)` — open tabs and bookmarks, filtered in memory.
///   2. `ChromiumBackend` / `SafariBackend` history SQL — filtered inside SQLite.
///   3. `FinderBackend` history search — filtered in memory over the local store.

// MARK: - URL match keys

/// Builds a stored match key for a URL: lowercased, accent-free, punctuation/symbols
/// removed, with loopback host synonyms (localhost, 127.0.0.1, 0.0.0.0, [::1]) indexed
/// so local development servers can be searched interchangeably by name or IP.
func foldURLForMatching(_ url: String) -> String {
    let base = foldForMatching(url)
    let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let host = URLComponents(string: trimmed)?.host?.lowercased() else {
        if url.contains("127.0.0.1") {
            return base + " localhost 0.0.0.0 0000"
        } else if url.contains("localhost") {
            return base + " 127.0.0.1 127001 0.0.0.0 0000"
        } else if url.contains("0.0.0.0") {
            return base + " localhost 127.0.0.1 127001"
        }
        return base
    }

    if host == "127.0.0.1" {
        return base + " localhost 0.0.0.0 0000"
    } else if host == "localhost" {
        return base + " 127.0.0.1 127001 0.0.0.0 0000"
    } else if host == "0.0.0.0" {
        return base + " localhost 127.0.0.1 127001"
    } else if host == "::1" || host == "[::1]" {
        return base + " localhost 127.0.0.1 127001 0.0.0.0 0000"
    }
    return base
}

// MARK: - SQLite predicate

/// Accent variants for each folded base letter, e.g. `"a"` maps to
/// `["à","À","á","Á",…]`. Derived from `accentedSearchCharacters` rather than
/// hand-listed per letter so the table can't drift out of sync with the folding
/// rules (CommandBarKit `SearchFolding.swift`).
private let accentVariantsByBaseLetter: [Character: [Character]] = {
    // Full Vietnamese vowel set plus common European Latin letters.
    let accentedSearchCharacters =
        "àáâãäåāăąạảấầẩẫậắằẳẵặ"
        + "èéêëēĕėęěẹẻẽếềểễệ"
        + "ìíîïĩīĭįịỉ"
        + "òóôõöøōŏőơọỏốồổỗộớờởỡợ"
        + "ùúûüũūŭůűưụủứừửữự"
        + "ỳýÿŷỵỷỹ"
        + "đñçćĉċčšśžźżťřłğ"

    var variants: [Character: [Character]] = [:]
    for accented in accentedSearchCharacters {
        let base = foldForMatching(String(accented))
        guard base.count == 1, let baseLetter = base.first else { continue }
        variants[baseLetter, default: []].append(accented)
        let uppercased = String(accented).uppercased()
        if uppercased.count == 1, let uppercasedLetter = uppercased.first {
            variants[baseLetter, default: []].append(uppercasedLetter)
        }
    }
    return variants
}()

/// One `GLOB` character class matching `character` in any case and with any
/// accent, e.g. `d` becomes `[dDđĐ]`.
///
/// `GLOB` rather than `LIKE` because SQLite's `LIKE` has no character classes
/// and its case-insensitivity is ASCII-only — neither can reach an accented
/// title. Input is always accent-free and separator-free (see `searchWords`),
/// so no glob metacharacter can appear here and nothing needs escaping.
private func globCharacterClass(for character: Character) -> String {
    var members: [Character] = []
    var seen: Set<Character> = []

    func append(_ candidate: Character) {
        if seen.insert(candidate).inserted { members.append(candidate) }
    }

    append(character)
    let uppercased = String(character).uppercased()
    if uppercased.count == 1, let uppercasedLetter = uppercased.first {
        append(uppercasedLetter)
    }
    for variant in accentVariantsByBaseLetter[character] ?? [] {
        append(variant)
    }

    if members.count == 1 { return String(members[0]) }
    return "[" + String(members) + "]"
}

/// A `GLOB` pattern matching `word` anywhere in a column, case- and
/// accent-insensitively.
func historySearchGlobPattern(for word: String) -> String {
    var pattern = "*"
    for character in word {
        pattern += globCharacterClass(for: character)
    }
    return pattern + "*"
}

/// SQLite's default `SQLITE_MAX_FUNCTION_ARG`. Longer patterns are built from
/// several concatenated `char()` calls rather than one oversized one.
private let sqliteMaxFunctionArguments = 120

/// A SQL expression evaluating to `pattern`.
///
/// An accented pattern **cannot** be sent as a plain SQL string literal:
/// Foundation's `Process` re-encodes every argument to Unicode NFD, so a
/// precomposed "à" reaches `sqlite3` as "a" + U+0300. That splits every accent
/// class into unrelated members and the pattern silently stops matching —
/// verified empirically, and the reason accented history search never worked.
///
/// Emitting the pattern as `char(0x…)` keeps the process argument pure ASCII,
/// so the string SQLite builds is exactly the one intended.
private func sqlStringExpression(for pattern: String) -> String {
    guard pattern.unicodeScalars.contains(where: { !$0.isASCII }) else {
        return "'" + pattern.replacingOccurrences(of: "'", with: "''") + "'"
    }

    let codePoints = pattern.unicodeScalars.map { "0x" + String($0.value, radix: 16) }
    return stride(from: 0, to: codePoints.count, by: sqliteMaxFunctionArguments)
        .map { start in
            let chunk = codePoints[start..<min(start + sqliteMaxFunctionArguments, codePoints.count)]
            return "char(" + chunk.joined(separator: ",") + ")"
        }
        .joined(separator: "||")
}

/// SQL boolean expression requiring every word of `query` to appear in either
/// `urlColumn` or `titleColumn`. Returns `"1"` (match everything) for an empty
/// query so callers can always splice it into their `WHERE` clause.
///
/// Known limits:
///   - Stored columns are matched as-is, so a query that *joins* words the page
///     separates with punctuation ("ecommerce" for "e-commerce") won't reach
///     history. Typing them apart ("e commerce") works.
///   - Accent classes are precomposed (NFC), which is what browsers store. A
///     title stored decomposed would need its accents typed to be found.
func historySearchSQLPredicate(query: String, urlColumn: String, titleColumn: String) -> String {
    let words = searchWords(in: query)
    guard !words.isEmpty else { return "1" }

    let is127Query = query.contains("127.0.0.1")

    return words.map { word in
        let pattern = sqlStringExpression(for: historySearchGlobPattern(for: word))
        if word == "localhost" {
            let ipPattern = sqlStringExpression(for: historySearchGlobPattern(for: "127.0.0.1"))
            return "(\(urlColumn) GLOB \(pattern) OR \(urlColumn) GLOB \(ipPattern) OR \(titleColumn) GLOB \(pattern))"
        } else if is127Query && (word == "127" || word == "0" || word == "1") {
            let localhostPattern = sqlStringExpression(for: historySearchGlobPattern(for: "localhost"))
            return "(\(urlColumn) GLOB \(pattern) OR \(urlColumn) GLOB \(localhostPattern) OR \(titleColumn) GLOB \(pattern))"
        }
        return "(\(urlColumn) GLOB \(pattern) OR \(titleColumn) GLOB \(pattern))"
    }.joined(separator: " AND ")
}

// MARK: - History page identity

/// Identity of a *page* for history dedup: scheme-less host + path, with the
/// query string and fragment dropped, `www.` and a trailing slash removed.
/// Non-default ports (anything other than standard 80/443) are preserved so
/// separate local services on distinct ports are never collapsed.
///
/// Deliberately coarse — two history rows only collapse when this *and* their
/// folded title match (see `HistorySearchExpansion.merge`), so distinct pages
/// that share a path but not a title (search-result pages, paginated views with
/// their own titles) survive.
func historyPageIdentity(forURL rawURL: String) -> String {
    let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let components = URLComponents(string: trimmed), let host = components.host else {
        // Non-URL history entries (e.g. Finder paths) fall back to the raw
        // string so they can never be collapsed into one another by accident.
        return trimmed.lowercased()
    }

    var normalizedHost = host.lowercased()
    if normalizedHost.hasPrefix("www.") {
        normalizedHost.removeFirst(4)
    }

    if let port = components.port, port != 80, port != 443 {
        normalizedHost += ":\(port)"
    }

    var path = components.percentEncodedPath
    while path.count > 1 && path.hasSuffix("/") {
        path.removeLast()
    }

    return normalizedHost + path
}


/// Matches a leading unread/notification-count badge like `"(2) "`,
/// `"(9+) "`, `"[3] "`, or `"• "`. Gmail, Slack, Notion and similar sites prefix the *live* tab
/// title with a count that changes between visits or polling ticks but
/// doesn't reflect a different page — left in place, it defeats title-based
/// duplicate detection by making every poll look like a new title.
private let leadingCountBadgePattern = try! NSRegularExpression(
    pattern: #"^(\([0-9]{1,3}\+?\)|\[[0-9]{1,3}\+?\]|[•*]|\([•*]\))\s*"#
)


/// Strips a leading count badge (see `leadingCountBadgePattern`) from `title`,
/// if present. Used only for duplicate-page detection — the badge is kept in
/// `BrowserSearchResult.title` itself so the row UI still shows it.
func strippingLeadingCountBadge(_ title: String) -> String {
    let range = NSRange(title.startIndex..<title.endIndex, in: title)
    guard let match = leadingCountBadgePattern.firstMatch(in: title, range: range),
          let matchRange = Range(match.range, in: title) else {
        return title
    }
    return String(title[matchRange.upperBound...])
}
