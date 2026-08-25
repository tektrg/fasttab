import Foundation

public enum SyncSearchMatcher {
    /// Folds a string by lowercasing, stripping diacritics/accents, and removing common punctuation.
    public static func fold(_ text: String) -> String {
        text
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Checks whether all words in the query appear in either the title or the URL.
    public static func matches(query: String, title: String, url: String) -> Bool {
        let foldedQuery = fold(query)
        guard !foldedQuery.isEmpty else { return true }

        let queryWords = foldedQuery.split(separator: " ")
        guard !queryWords.isEmpty else { return true }

        let foldedCombined = fold("\(title) \(url)")

        for word in queryWords {
            if !foldedCombined.contains(word) {
                return false
            }
        }
        return true
    }

    /// Checks whether all words in the query appear in the target text.
    public static func matches(query: String, target: String) -> Bool {
        matches(query: query, title: target, url: "")
    }
}
