import Foundation

/// FastTab's wording for the on-device transcript clean-up (engine: IndieTextCleanup).
/// LIGHT only: the reader must still be able to trust every sentence as what was said.
enum TranscriptCleanup {
    static let instruction = """
    You lightly clean up spoken transcript text. Add punctuation and capital letters, remove \
    filler words (um, uh, like, you know) and accidental repeats, and join broken sentences. \
    Keep every idea, every fact and the speaker's own words. Do not summarise, shorten, \
    reorder, explain or add anything.
    """
}
