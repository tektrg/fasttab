import Foundation

/// A place in the article for Read Aloud: UTF-16 `offset` inside `chunks[chunk]`
/// (the same space as the engines' word / sentence ranges).
struct ReadAloudPosition: Equatable, Sendable {
    var chunk: Int
    var offset: Int
}

/// "Back 15 s" / "Forward 15 s" for spoken text. Engines report no audio clock that works
/// across all voices, so time is estimated from text length:
///
/// 1. 15 s ≈ `charactersPerSecond` × 15 × speed characters (≈ 225 at 1.0×).
/// 2. Move that many characters from the current position, across paragraphs (chunks).
/// 3. Snap to the start of the sentence nearest that target, always strictly in the skip
///    direction (so a press never stays put).
/// 4. Back before the first sentence → the very beginning; forward with nothing left (or a
///    target past the end) → `.end` (the caller stops).
///
/// Pure: no engine, no UI.
enum ReadAloudSkip {
    enum Direction: Sendable { case backward, forward }

    enum Target: Equatable {
        case position(ReadAloudPosition)
        /// Skipped past the last sentence.
        case end
    }

    /// Lock screen / headphone and transport-bar interval.
    static let interval: TimeInterval = 15

    /// Average English speech at 1.0× ≈ 150 words/min ≈ 15 characters/s (≈ 6 characters a
    /// word with its space). v1 applies it to every language; it only sizes a skip and the
    /// lock screen's estimated elapsed time, never playback itself.
    static let charactersPerSecond = 15.0

    /// Characters spoken in `seconds` at `rate` (speed multiplier).
    static func characters(in seconds: TimeInterval, rate: Double) -> Int {
        Int((seconds * charactersPerSecond * max(rate, 0.1)).rounded())
    }

    static func target(
        chunks: [String],
        from position: ReadAloudPosition,
        rate: Double,
        direction: Direction,
        seconds: TimeInterval = interval
    ) -> Target {
        guard !chunks.isEmpty else { return .end }
        let starts = chunkStarts(chunks)
        let current = characterOffset(of: position, starts: starts, chunks: chunks)
        let distance = characters(in: seconds, rate: rate)
        let sentences = chunks.indices.flatMap { chunk in
            ReadAloudSentences.split(chunks[chunk], chunk: chunk).map {
                (global: starts[chunk] + $0.range.location, position: ReadAloudPosition(chunk: chunk, offset: $0.range.location))
            }
        }
        switch direction {
        case .backward:
            let goal = current - distance
            let candidates = sentences.filter { $0.global < current }
            guard goal > 0, let nearest = candidates.min(by: { abs($0.global - goal) < abs($1.global - goal) }) else {
                return .position(ReadAloudPosition(chunk: 0, offset: 0))
            }
            return .position(nearest.position)
        case .forward:
            let goal = current + distance
            let total = starts[chunks.count - 1] + (chunks[chunks.count - 1] as NSString).length
            let candidates = sentences.filter { $0.global > current }
            guard goal < total, let nearest = candidates.min(by: { abs($0.global - goal) < abs($1.global - goal) }) else {
                return .end
            }
            return .position(nearest.position)
        }
    }

    /// Estimated (elapsed, total) seconds of the whole article at `rate`, for Now Playing.
    static func estimatedTimeline(chunks: [String], at position: ReadAloudPosition, rate: Double)
        -> (elapsed: TimeInterval, duration: TimeInterval) {
        guard !chunks.isEmpty else { return (0, 0) }
        let starts = chunkStarts(chunks)
        let total = starts[chunks.count - 1] + (chunks[chunks.count - 1] as NSString).length
        let perSecond = charactersPerSecond * max(rate, 0.1)
        let elapsed = Double(characterOffset(of: position, starts: starts, chunks: chunks)) / perSecond
        return (elapsed, Double(total) / perSecond)
    }

    /// UTF-16 start of each chunk in the article read as one string (no separators).
    private static func chunkStarts(_ chunks: [String]) -> [Int] {
        var starts: [Int] = []
        var running = 0
        for chunk in chunks {
            starts.append(running)
            running += (chunk as NSString).length
        }
        return starts
    }

    /// `position` in that one-string space, clamped into the article.
    private static func characterOffset(of position: ReadAloudPosition, starts: [Int], chunks: [String]) -> Int {
        let chunk = min(max(position.chunk, 0), chunks.count - 1)
        let offset = min(max(position.offset, 0), (chunks[chunk] as NSString).length)
        return starts[chunk] + offset
    }
}

/// Starting speech partway into a chunk, for any `SpeechEngine`: the engine gets that chunk
/// cut to begin at `offset`, and its word / sentence ranges in that chunk are shifted back so
/// highlights still land on the page text. Used by Read Aloud skips and the engines' own
/// device-voice fallbacks.
enum ReadAloudMidChunkStart {
    static func cut(_ chunks: [String], chunk: Int, offset: Int) -> [String] {
        guard offset > 0, chunks.indices.contains(chunk) else { return chunks }
        var cut = chunks
        cut[chunk] = (chunks[chunk] as NSString).substring(from: min(offset, (chunks[chunk] as NSString).length))
        return cut
    }

    static func shift(_ event: SpeechEngineEvent, inChunk chunk: Int, by offset: Int) -> SpeechEngineEvent {
        guard offset != 0 else { return event }
        func moved(_ range: NSRange) -> NSRange { NSRange(location: range.location + offset, length: range.length) }
        switch event {
        case .word(chunk, let range): return .word(chunk: chunk, range: moved(range))
        case .sentence(chunk, let range): return .sentence(chunk: chunk, range: moved(range))
        default: return event
        }
    }
}
