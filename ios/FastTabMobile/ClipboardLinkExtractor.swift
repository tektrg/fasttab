import Foundation

/// Pulls every http(s) link out of free text (e.g. the clipboard), in order, deduped.
enum ClipboardLinkExtractor {
    static func links(in text: String) -> [URL] {
        guard !text.isEmpty,
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return []
        }
        var seen = Set<String>()
        var result: [URL] = []
        for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let url = match.url,
                  let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
                  seen.insert(url.absoluteString.lowercased()).inserted else { continue }
            result.append(url)
        }
        return result
    }
}
