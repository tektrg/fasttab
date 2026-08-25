import Foundation

/// Single source of truth for "does what the user typed match this text".
///
/// Three consumers, all of which must agree or search feels inconsistent
/// depending on where a result came from:
///   1. `BrowserSearchResult.matches(query:)` — open tabs and bookmarks, filtered in memory.
///   2. `ChromiumBackend` / `SafariBackend` history SQL — filtered inside SQLite.
///   3. `FinderBackend` history search — filtered in memory over the local store.
///
/// Two rules define the behaviour:
///   - **Every word must appear somewhere** (title or URL), in any order. So
///     "real time bi hub" matches "Realtime e-commerce order | Bi Hub".
///   - **Accents and case are optional.** "don hang" matches "Đơn hàng".

// MARK: - Folding

/// Characters that split a typed query into words, and that are removed from
/// stored match keys. Punctuation and symbols are both included so that `|`
/// (a *symbol*, not punctuation) behaves like `-` (punctuation) — and so that
/// glob metacharacters (`*`, `?`, `[`, `]`, `^`) can never survive into a
/// generated SQL pattern. Whitespace splits queries but is preserved in keys.
private let searchWordSeparators: CharacterSet = {
    var separators = CharacterSet.punctuationCharacters
    separators.formUnion(.symbols)
    return separators
}()

private let searchWordSeparatorsWithWhitespace: CharacterSet = {
    var separators = searchWordSeparators
    separators.formUnion(.whitespacesAndNewlines)
    return separators
}()

/// Fixed locale so case folding never depends on the user's region (Turkish
/// locales fold `I` to `ı`, which would silently break matching).
private let searchFoldingLocale = Locale(identifier: "en_US_POSIX")

/// Letters whose diacritic is a *stroke* rather than a combining mark.
/// `.diacriticInsensitive` folding leaves these untouched — Unicode considers
/// `đ` a distinct letter, not `d` + accent — so Vietnamese "Đơn hàng" would
/// stay unreachable from "don hang" without this explicit step.
private let strokeLetterBaseForms: [(stroke: String, base: String)] = [
    ("đ", "d"), ("Đ", "d"),
    ("ø", "o"), ("Ø", "o"),
    ("ł", "l"), ("Ł", "l")
]

/// Lowercases and removes accents. Punctuation is left in place — callers
/// decide whether to strip it (match keys) or split on it (query words).
private func foldCaseAndAccents(_ text: String) -> String {
    guard !text.isEmpty else { return "" }

    var folded = text
    for (stroke, base) in strokeLetterBaseForms where folded.contains(stroke) {
        folded = folded.replacingOccurrences(of: stroke, with: base)
    }
    return folded.folding(
        options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive],
        locale: searchFoldingLocale
    )
}

/// Builds a stored match key: lowercased, accent-free, and with punctuation and
/// symbols removed so "e-commerce" and "ecommerce" reduce to the same text.
/// Whitespace is preserved so words in the key stay separated.
///
/// Called once per result at construction (see `BrowserSearchResult`'s
/// `normalizedTitleKey`), never per keystroke — the typing path only folds the
/// short query string and then does plain substring checks.
func foldForMatching(_ text: String) -> String {
    foldCaseAndAccents(text)
        .components(separatedBy: searchWordSeparators)
        .joined()
}

/// Splits a typed query into the words that must *all* be found.
///
/// Splits on punctuation as well as whitespace, so typing a URL fragment works:
/// "sevensystem.vn" becomes ["sevensystem", "vn"] and matches a page on that
/// host whether or not the stored URL has "www." in front of it. Splitting
/// rather than stripping also keeps the SQL side honest — history columns are
/// matched as stored, so a word must never span a punctuation boundary.
func searchWords(in query: String) -> [String] {
    foldCaseAndAccents(query)
        .components(separatedBy: searchWordSeparatorsWithWhitespace)
        .filter { !$0.isEmpty }
}

/// True when every one of `words` appears in at least one of `keys`.
/// `keys` must already be folded via `foldForMatching`; `words` must already
/// be folded via `searchWords(in:)`.
///
/// Callers matching many candidates against the same typed query (searching
/// hundreds of tabs/bookmarks/history rows per keystroke) must fold the query
/// into `words` once up front and reuse it — re-running `searchWords(in:)`
/// per candidate repeats the same Unicode case/accent/width folding on
/// identical input hundreds of times over.
func foldedKeys(_ keys: [String], containAllWordsOf words: [String]) -> Bool {
    guard !words.isEmpty else { return true }
    return words.allSatisfy { word in
        keys.contains { $0.contains(word) }
    }
}

// MARK: - SQLite predicate

/// Accent variants for each folded base letter, e.g. `"a"` maps to
/// `["à","À","á","Á",…]`. Derived from `accentedSearchCharacters` rather than
/// hand-listed per letter so the table can't drift out of sync with the folding
/// rules above.
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

    return words.map { word in
        let pattern = sqlStringExpression(for: historySearchGlobPattern(for: word))
        return "(\(urlColumn) GLOB \(pattern) OR \(titleColumn) GLOB \(pattern))"
    }.joined(separator: " AND ")
}

// MARK: - History page identity

/// Identity of a *page* for history dedup: scheme-less host + path, with the
/// query string and fragment dropped, `www.` and a trailing slash removed.
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

    var path = components.percentEncodedPath
    while path.count > 1 && path.hasSuffix("/") {
        path.removeLast()
    }

    return normalizedHost + path
}

// MARK: - Duplicate-page title normalization

/// Matches a leading unread/notification-count badge like `"(2) "` or
/// `"(12) "`. Gmail, Slack, Notion and similar sites prefix the *live* tab
/// title with a count that changes between visits or polling ticks but
/// doesn't reflect a different page — left in place, it defeats title-based
/// duplicate detection by making every poll look like a new title.
private let leadingCountBadgePattern = try! NSRegularExpression(pattern: "^\\(\\d+\\)\\s*")

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
