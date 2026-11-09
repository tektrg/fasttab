import Foundation

/// What the Summary sends to the server: the article as plain text, capped, plus the two checks
/// the server makes too (so a too-short page never costs a round trip). Pure, so it is unit-tested.
enum ReaderSummaryText {
    /// Mirrors theindie-api `reader_ai_text_too_short`: shorter than this is not worth summarizing.
    static let minCharacters = 1_200
    /// Mirrors the server's hard limit; longer text is cut in the middle (start and end are kept).
    static let maxCharacters = 60_000
    private static let headCharacters = 40_000
    private static let tailCharacters = 19_000
    private static let cutMarker = "\n\n[…]\n\n"

    struct Input: Equatable {
        let text: String
        /// Bare or regional BCP-47 code the server accepts ("vi", "en-US"); nil = "same as the article".
        let languageCode: String?
    }

    enum Prepared: Equatable {
        case ready(Input)
        case tooShort
    }

    static func prepare(article: ReaderArticle) -> Prepared {
        let title = article.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let paragraphs = ReadAloudText.paragraphs(fromHTML: article.content)
        let full = ((title.isEmpty ? [] : [title]) + paragraphs).joined(separator: "\n\n")
        guard full.count >= minCharacters else { return .tooShort }
        let language = ReadAloudText.dominantLanguage(of: paragraphs).flatMap(acceptableLanguageCode)
        return .ready(Input(text: capped(full), languageCode: language))
    }

    /// The server counts UTF-16 units (JavaScript `.length`), not Swift characters: accents written
    /// as separate marks or emoji count more there, so the cap is checked in UTF-16 units too.
    static func capped(_ text: String) -> String {
        guard text.count > maxCharacters || text.utf16.count > maxCharacters else { return text }
        var head = headCharacters
        var result = ""
        repeat {
            result = String(text.prefix(head)) + cutMarker + String(text.suffix(tailCharacters))
            head -= 2_000
        } while result.utf16.count > maxCharacters && head > 0
        return result
    }

    /// Only shapes like "vi" / "en-US" / "zh-Hans"; anything else is left to the server's default.
    static func acceptableLanguageCode(_ code: String) -> String? {
        code.range(of: "^[a-z]{2,3}(-[A-Za-z0-9]{2,8})?$", options: .regularExpression) != nil ? code : nil
    }
}
