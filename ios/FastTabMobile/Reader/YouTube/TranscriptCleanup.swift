import Foundation
import IndieTextCleanup

/// FastTab's wording for the on-device transcript clean-up (engine: IndieTextCleanup).
/// LIGHT only: the reader must still be able to trust every sentence as what was said.
enum TranscriptCleanup {
    /// One chunk at a time: measured on an iPhone 16e (2026-10-01), 2 at once was slower and
    /// hit rate limits, 4 at once was refused outright (TranscriptCleanupSpeedTest).
    static let maxConcurrentChunks = 1

    /// Bump when the instruction changes in a way worth re-cleaning saved videos for
    /// (TranscriptCleanupStore drops records made under another version).
    static let instructionVersion = 3

    /// Filler and opener removal shortens more than plain punctuation does, so the floor sits
    /// at half the original length (a summary still lands well under it).
    static let validator = CleanupValidator(acceptedLengthRatio: 0.5...1.3)

    static let instruction = """
    You turn raw speech-to-text into readable prose. The input has no punctuation; you must \
    add it: split it into sentences with periods, commas and question marks, and capitalise \
    the first word of each sentence. Remove filler words and verbal tics (um, uh, like, you know, \
    basically, I mean, kind of, sort of, okay, alright, right), a "so" or "and" that only opens \
    a sentence, and accidental repeated words. Keep every idea, fact and the speaker's own words \
    in order. Do not summarise, shorten, explain or add anything.
    Where the speaker moves on to a new point, start a new paragraph with a blank line; keep \
    paragraphs to a few sentences.
    Example input:
    [[1]]
    okay so um basically we we take the the model and uh we train it on like a lot of text and then it can you know predict the next word so that's the training part okay and now the second stage is fine tuning where we change the data set
    Example output:
    [[1]]
    We take the model and train it on a lot of text, and then it can predict the next word. That's the training part.

    The second stage is fine tuning, where we change the data set.
    """

    /// Sentence openers the model often keeps despite the instruction ("Okay, so", "So,").
    /// Removed here, deterministically, from the start of every sentence and paragraph.
    private static let openers = try! Regex(#"(?i)(^|[.?!]\s+|\n\s*)((?:okay|ok|alright|all right|so|and so|anyway)(?:,\s*|\s+))+(?=\w)"#)

    /// The model's text with leftover filler openers removed and the next word capitalised.
    static func polish(_ text: String) -> String {
        var result = text
        while let match = result.firstMatch(of: openers) {
            let lead = match.output[1].substring.map(String.init) ?? ""
            let rest = result[match.range.upperBound...]
            let capitalised = rest.prefix(1).uppercased() + rest.dropFirst()
            result = String(result[..<match.range.lowerBound]) + lead + capitalised
        }
        return result
    }
}
