import Foundation

/// Single source of truth for "does what the user typed match this text".
///
/// Every consumer (in-memory filtering, SQL predicates built from
/// `searchWords(in:)`) must go through these helpers, or search feels
/// inconsistent depending on where a result came from.
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
/// Call once per result at construction (FastTab: `BrowserSearchResult`'s
/// `normalizedTitleKey`), never per keystroke — the typing path only folds the
/// short query string and then does plain substring checks.
public func foldForMatching(_ text: String) -> String {
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
public func searchWords(in query: String) -> [String] {
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
public func foldedKeys(_ keys: [String], containAllWordsOf words: [String]) -> Bool {
    guard !words.isEmpty else { return true }
    return words.allSatisfy { word in
        keys.contains { $0.contains(word) }
    }
}
