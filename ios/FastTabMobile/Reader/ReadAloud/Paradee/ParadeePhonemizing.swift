import Foundation

/// Which phoneme dictionary Paradee's text-to-phoneme step uses. American voices
/// (af_heart, am_puck) need American phonemes; British voices (bf_isabella, bm_fable)
/// need British ones — the model was trained on misaki's spelling of each.
enum ParadeeAccent: Sendable {
    case american
    case british
}

/// English text → phoneme string in misaki's notation (the same characters Paradee's
/// `config.json` vocab maps to token ids). Words are separated by spaces and punctuation
/// is kept, exactly as misaki would emit it, so the model hears pauses.
protocol ParadeePhonemizing: Sendable {
    func phonemes(for text: String, accent: ParadeeAccent) -> String
}
