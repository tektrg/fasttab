import Foundation

/// What is being spoken right now: a word inside one chunk of one playback session.
/// Ranges are UTF-16 (`NSRange`), as speech engines and JavaScript both count.
struct ReadAloudSpokenPosition: Equatable {
    /// Bumped on every `start`, so the page knows when to rebuild its text map.
    let sessionID: Int
    let chunkIndex: Int
    let wordRange: NSRange
}

/// Paragraph + word ranges in the page's normalised text (see `ftReadAloudText` in
/// `reader_template.html`): whitespace collapsed to single spaces, UTF-16 offsets.
struct ReadAloudDocumentRanges: Equatable {
    let paragraph: NSRange
    let word: NSRange
}

/// Maps spoken chunks back onto the rendered article text. Chunks are found in
/// reading order (each search starts where the previous chunk ended), so repeated
/// phrases resolve to the right occurrence. A chunk the page doesn't contain
/// (e.g. a transcript paragraph re-cleaned since) maps to nil: no highlight.
struct ReadAloudTextLocator {
    /// UTF-16 offset of each chunk in the document text; nil when not found.
    let chunkStarts: [Int?]
    private let chunkLengths: [Int]

    init(documentText: String, chunks: [String]) {
        let document = documentText as NSString
        var cursor = 0
        var starts: [Int?] = []
        for chunk in chunks {
            let afterCursor = NSRange(location: cursor, length: document.length - cursor)
            var found = document.range(of: chunk, options: .literal, range: afterCursor)
            if found.location == NSNotFound {
                // Out of order (e.g. the title also appears in the body): search everywhere.
                found = document.range(of: chunk, options: .literal)
            }
            if found.location == NSNotFound {
                starts.append(nil)
            } else {
                starts.append(found.location)
                cursor = max(cursor, found.location + found.length)
            }
        }
        chunkStarts = starts
        chunkLengths = chunks.map { ($0 as NSString).length }
    }

    func documentRanges(for position: ReadAloudSpokenPosition) -> ReadAloudDocumentRanges? {
        guard chunkStarts.indices.contains(position.chunkIndex),
              let chunkStart = chunkStarts[position.chunkIndex] else { return nil }
        let chunkLength = chunkLengths[position.chunkIndex]
        let wordStart = min(max(position.wordRange.location, 0), chunkLength)
        let wordLength = min(max(position.wordRange.length, 0), chunkLength - wordStart)
        return ReadAloudDocumentRanges(
            paragraph: NSRange(location: chunkStart, length: chunkLength),
            word: NSRange(location: chunkStart + wordStart, length: wordLength)
        )
    }
}
