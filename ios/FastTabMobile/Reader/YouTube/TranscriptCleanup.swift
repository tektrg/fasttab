import Foundation

/// FastTab's wording for the on-device transcript clean-up (engine: IndieTextCleanup).
/// LIGHT only: the reader must still be able to trust every sentence as what was said.
enum TranscriptCleanup {
    static let instruction = """
    You turn raw speech-to-text into readable prose. The input has no punctuation; you must \
    add it: split it into sentences with periods, commas and question marks, and capitalise \
    the first word of each sentence. Remove filler words (um, uh, like, you know, basically) \
    and accidental repeated words. Keep every idea, fact and the speaker's own words in order. \
    Do not summarise, shorten, explain or add anything.
    Example input:
    [[1]]
    so um basically we we take the the model and uh we train it on like a lot of text and then it can you know predict the next word
    Example output:
    [[1]]
    So we take the model and train it on a lot of text, and then it can predict the next word.
    """
}
