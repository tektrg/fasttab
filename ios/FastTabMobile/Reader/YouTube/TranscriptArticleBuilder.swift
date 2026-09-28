import Foundation
import IndieTranscripts

/// Turns a transcript into a `ReaderArticle` the reader template renders like any article:
/// one `<p class="ft-transcript-paragraph">` per paragraph, each led by a tappable timestamp.
/// `data-start-ms` on both is what the page's player sync (reader_template.html) reads.
enum TranscriptArticleBuilder {
    static func article(from transcript: Transcript, url: URL, videoID: String,
                        title fallbackTitle: String, channel: String?) -> ReaderArticle {
        let paragraphs = TranscriptParagraphs(transcript).paragraphs
        let title = [transcript.title, fallbackTitle].compactMap { $0?.trimmed }.first { !$0.isEmpty } ?? "YouTube video"
        let kindNote = transcript.kind == .asr ? "Auto-generated transcript" : "Transcript"
        let byline = [channel?.trimmed, kindNote].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        return ReaderArticle(
            title: title,
            byline: byline,
            siteName: "YouTube",
            content: html(for: paragraphs),
            excerpt: String(paragraphs.first?.text.prefix(200) ?? ""),
            url: url,
            youtubeVideoID: videoID
        )
    }

    static func html(for paragraphs: [TranscriptParagraph]) -> String {
        paragraphs.map { paragraph in
            let ms = paragraph.startMs
            return "<p class=\"ft-transcript-paragraph\" data-start-ms=\"\(ms)\">"
                + "<button type=\"button\" class=\"ft-ts\" data-start-ms=\"\(ms)\">\(timestamp(ms: ms))</button> "
                + escapeHTML(paragraph.text) + "</p>"
        }.joined(separator: "\n")
    }

    /// `m:ss`, or `h:mm:ss` from an hour on.
    static func timestamp(ms: Int) -> String {
        let total = max(0, ms) / 1000
        let hours = total / 3600, minutes = (total % 3600) / 60, seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }

    static func escapeHTML(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(character)
            }
        }
        return out
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
