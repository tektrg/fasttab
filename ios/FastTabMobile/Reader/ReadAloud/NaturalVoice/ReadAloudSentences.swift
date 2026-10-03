import Foundation

/// One sentence of a Read Aloud chunk: the unit the natural voice requests, caches and
/// highlights. `range` is UTF-16, within the chunk (the same space as word ranges).
struct ReadAloudSentence: Equatable, Sendable {
    let chunk: Int
    let range: NSRange
    let text: String
}

enum ReadAloudSentences {
    /// Sentences of one chunk, trimmed, in order. Text the tokenizer can't split comes back whole.
    static func split(_ chunkText: String, chunk: Int) -> [ReadAloudSentence] {
        let ns = chunkText as NSString
        var sentences: [ReadAloudSentence] = []
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .bySentences) { _, range, _, _ in
            if let trimmed = trimmedRange(range, in: ns) {
                sentences.append(ReadAloudSentence(chunk: chunk, range: trimmed, text: ns.substring(with: trimmed)))
            }
        }
        if sentences.isEmpty, let whole = trimmedRange(NSRange(location: 0, length: ns.length), in: ns) {
            sentences = [ReadAloudSentence(chunk: chunk, range: whole, text: ns.substring(with: whole))]
        }
        return sentences
    }

    /// Every sentence of `chunks[startIndex...]`, in reading order.
    static func sentences(of chunks: [String], from startIndex: Int) -> [ReadAloudSentence] {
        chunks.indices.filter { $0 >= startIndex }.flatMap { split(chunks[$0], chunk: $0) }
    }

    private static func trimmedRange(_ range: NSRange, in text: NSString) -> NSRange? {
        var start = range.location
        var end = range.location + range.length
        func isSpace(_ index: Int) -> Bool {
            guard let scalar = Unicode.Scalar(text.character(at: index)) else { return false }
            return CharacterSet.whitespacesAndNewlines.contains(scalar)
        }
        while start < end, isSpace(start) { start += 1 }
        while end > start, isSpace(end - 1) { end -= 1 }
        return end > start ? NSRange(location: start, length: end - start) : nil
    }
}
