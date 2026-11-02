import Foundation

/// `paradee_config.json` (the model card's `config.json`, renamed so it can't collide in the
/// app bundle): sample rate, voice order and the phoneme vocabulary.
struct ParadeeConfig: Decodable, Sendable {
    let sampleRate: Int
    /// Voice names in the order the model numbers them (its `voice` input).
    let voices: [String]
    let vocab: [String: Int64]

    enum CodingKeys: String, CodingKey {
        case sampleRate = "sample_rate", voices, vocab
    }

    /// The model's `voice` input for `voice`; nil when this model doesn't have it.
    func index(of voice: ParadeeVoice) -> Int64? {
        voices.firstIndex(of: voice.rawValue).map(Int64.init)
    }
}

/// Phoneme string → model token ids, the way the reference Python package does it: one id
/// per Unicode scalar (not per `Character`: combining marks are their own tokens), unknown
/// scalars dropped, a `0` pad at each end, at most 512 ids in all.
struct ParadeeTokenizer: Sendable {
    /// 512 positions minus the two pads.
    static let maxIDs = 510
    static let padID: Int64 = 0

    private let vocab: [Unicode.Scalar: Int64]
    private let spaceID: Int64?
    /// Clause ends (; : , — … . ! ?): preferred places to cut a sentence that is too long.
    private let breakIDs: Set<Int64>

    init(vocab: [String: Int64]) {
        var scalars: [Unicode.Scalar: Int64] = [:]
        for (key, id) in vocab where key.unicodeScalars.count == 1 {
            scalars[key.unicodeScalars.first!] = id
        }
        self.vocab = scalars
        spaceID = scalars[" "]
        breakIDs = Set(";:,—….!?".unicodeScalars.compactMap { scalars[$0] })
    }

    /// Unpadded ids; scalars the model doesn't know are dropped.
    func ids(for phonemes: String) -> [Int64] {
        phonemes.unicodeScalars.compactMap { vocab[$0] }
    }

    static func padded(_ ids: [Int64]) -> [Int64] {
        [padID] + ids + [padID]
    }

    /// `ids` cut into pieces of at most `maxIDs`, only at spaces (word boundaries): at the last
    /// clause end in the second half of the window when there is one, else at the last space.
    /// A single "word" longer than `maxIDs` (no space at all) is the only hard cut.
    func pieces(of ids: [Int64], maxIDs: Int = maxIDs) -> [[Int64]] {
        var pieces: [[Int64]] = []
        var rest = trimmed(ids[...])
        while rest.count > maxIDs {
            let start = rest.startIndex
            // A space at offset `maxIDs` still leaves a full first piece before it.
            let window = start...(start + maxIDs)
            let spaces = window.filter { rest[$0] == spaceID && $0 > start }
            let clauseEnd = spaces.last { $0 - start >= maxIDs / 2 && breakIDs.contains(rest[$0 - 1]) }
            let cut = clauseEnd ?? spaces.last ?? start + maxIDs
            pieces.append(Array(trimmed(rest[..<cut])))
            rest = trimmed(rest[cut...])
        }
        if !rest.isEmpty { pieces.append(Array(rest)) }
        return pieces.filter { !$0.isEmpty }
    }

    private func trimmed(_ slice: ArraySlice<Int64>) -> ArraySlice<Int64> {
        var slice = slice
        while let first = slice.first, first == spaceID { slice = slice.dropFirst() }
        while let last = slice.last, last == spaceID { slice = slice.dropLast() }
        return slice
    }
}
