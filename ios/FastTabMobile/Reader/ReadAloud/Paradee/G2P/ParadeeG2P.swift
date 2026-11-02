import Foundation

/// On-device English text → phonemes for Paradee, in misaki's notation (the G2P Kokoro and
/// Paradee were trained with). A Swift port of misaki's `en.G2P` pipeline (misaki 0.9.4,
/// https://github.com/hexgrad/misaki, Apache 2.0; notice in `G2PData/misaki-LICENSE.txt`):
///
/// 1. tokenize + tag (`Tokenizer`: spaCy's rules + a small rule tagger instead of spaCy's model),
/// 2. `retokenize` into words / no-space word groups ("well-known", "$4.2", "iOS"),
/// 3. right-to-left lexicon pass (`Lexicon`: gold → silver dictionaries, stress, numbers),
/// 4. out-of-dictionary words: misaki uses espeak-ng (GPL); we use `Fallback` instead
///    (dictionary-backed affix/compound splits, then learned letter-to-sound rules, then spelling).
///
/// Dictionaries load lazily, once per accent per process, and are shared by every instance.
struct ParadeeG2P: ParadeePhonemizing {
    private let bundle: Bundle

    init(bundle: Bundle = .main) {
        self.bundle = bundle
    }

    func phonemes(for text: String, accent: ParadeeAccent) -> String {
        let resources = Self.cache.resources(for: accent, bundle: bundle)
        return Pipeline(lexicon: resources.lexicon, fallback: resources.fallback, heteronyms: resources.heteronyms).run(text)
    }

    /// Loads everything an accent needs now instead of on the first sentence.
    func preload(_ accent: ParadeeAccent) {
        _ = Self.cache.resources(for: accent, bundle: bundle)
    }

    // MARK: Resources

    struct Resources: Sendable {
        let lexicon: Lexicon
        let fallback: Fallback
        let heteronyms: Set<String>
    }

    private static let cache = ResourceCache()

    private final class ResourceCache: @unchecked Sendable {
        private let lock = NSLock()
        private var loaded: [String: Resources] = [:]

        func resources(for accent: ParadeeAccent, bundle: Bundle) -> Resources {
            let prefix = accent == .british ? "gb" : "us"
            let key = "\(prefix)|\(bundle.bundlePath)"
            lock.lock()
            defer { lock.unlock() }
            if let hit = loaded[key] { return hit }
            let golds = Self.store("paradee-\(prefix)-gold", bundle)
            let silvers = Self.store("paradee-\(prefix)-silver", bundle)
            let lexicon = Lexicon(british: accent == .british, golds: golds, silvers: silvers)
            let rules = Self.store("paradee-\(prefix)-lts", bundle)
            let resources = Resources(lexicon: lexicon, fallback: Fallback(lexicon: lexicon, rules: rules),
                                      heteronyms: golds.taggedKeys())
            loaded[key] = resources
            return resources
        }

        private static func store(_ name: String, _ bundle: Bundle) -> LexiconStore {
            guard let url = bundle.url(forResource: name, withExtension: "lzfse"),
                  let packed = try? Data(contentsOf: url, options: .mappedIfSafe),
                  let data = try? (packed as NSData).decompressed(using: .lzfse) as Data else {
                assertionFailure("ParadeeG2P: missing resource \(name).lzfse")
                return .empty
            }
            return LexiconStore(bytes: [UInt8](data))
        }
    }

    // MARK: Pipeline (misaki `G2P.__call__`)

    struct Pipeline {
        let lexicon: Lexicon
        let fallback: Fallback
        let heteronyms: Set<String>

        static let subtokenJunks: Set<Character> = Set("',-._‘’/")
        static let puncts: Set<Character> = Set(";:,.!?—…\"“”")
        static let nonQuotePuncts: Set<Character> = Set(";:,.!?—…")
        static let punctTags: Set<String> = [".", ",", "-LRB-", "-RRB-", "``", "\"\"", "''", ":", "$", "#", "NFP"]
        static let punctTagPhonemes: [String: String] = ["-LRB-": "(", "-RRB-": ")", "``": "\u{201C}", "\"\"": "\u{201D}", "''": "\u{201D}"]
        static let linkRegex = try! NSRegularExpression(pattern: #"\[([^\]]+)\]\(([^\)]*)\)"#)
        static let subtokenRegex = try! NSRegularExpression(pattern:
            #"^['‘’]+|\p{Lu}(?=\p{Lu}\p{Ll})|(?:^-)?(?:\d?[,.]?\d)+|[-_]+|['‘’]{2,}|\p{L}*?(?:['‘’]\p{L})*?\p{Ll}(?=\p{Lu})|\p{L}+(?:['‘’]\p{L})*|[^-_\p{L}'‘’\d]|['‘’]+$"#)

        /// A word is one token, or a group of tokens written without spaces between them.
        struct Word {
            var tokens: [Token]
            var isGroup: Bool
        }

        func run(_ input: String) -> String {
            // misaki's preprocess: markdown-style [text](feature) links keep only their text.
            let ns = input as NSString
            let text = Self.linkRegex.stringByReplacingMatches(in: input, range: NSRange(location: 0, length: ns.length), withTemplate: "$1")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return "" }
            let tokens = Tokenizer.tokens(text, isWord: { lexicon.golds.contains($0) || lexicon.silvers.contains($0) }, heteronyms: heteronyms)
            var words = retokenize(tokens)
            var ctx = TokenContext()
            for i in words.indices.reversed() {
                if !words[i].isGroup {
                    var w = words[i].tokens[0]
                    if w.phonemes == nil { (w.phonemes, w.rating) = lexicon.phonemes(for: w, ctx: ctx) }
                    if w.phonemes == nil { (w.phonemes, w.rating) = fallback.phonemes(for: w, ctx: ctx) }
                    ctx = Self.tokenContext(ctx, w.phonemes, w)
                    words[i].tokens[0] = w
                    continue
                }
                var w = words[i].tokens
                var left = 0, right = w.count
                var shouldFallback = false
                while left < right {
                    let span = w[left..<right]
                    let tk: Token? = span.contains(where: { $0.alias != nil || $0.phonemes != nil }) ? nil : Self.merge(Array(span), unk: nil)
                    let (ps, rating) = tk.map { lexicon.phonemes(for: $0, ctx: ctx) } ?? (nil, nil)
                    if let ps, let tk {
                        w[left].phonemes = ps
                        w[left].rating = rating
                        for x in (left + 1)..<right { w[x].phonemes = "" }
                        ctx = Self.tokenContext(ctx, ps, tk)
                        right = left
                        left = 0
                    } else if left + 1 < right {
                        left += 1
                    } else {
                        right -= 1
                        if w[right].phonemes == nil {
                            if w[right].text.allSatisfy(Self.subtokenJunks.contains) {
                                w[right].phonemes = ""
                                w[right].rating = 3
                            } else {
                                shouldFallback = true
                                break
                            }
                        }
                        left = 0
                    }
                }
                if shouldFallback {
                    let tk = Self.merge(w, unk: nil)
                    (w[0].phonemes, w[0].rating) = fallback.phonemes(for: tk, ctx: ctx)
                    for j in 1..<w.count { w[j].phonemes = "" }
                } else {
                    Self.resolve(&w)
                }
                words[i].tokens = w
            }
            var out = ""
            for word in words {
                let tk = word.isGroup ? Self.merge(word.tokens, unk: "") : word.tokens[0]
                let ps = (tk.phonemes ?? "").replacingOccurrences(of: "ɾ", with: "T").replacingOccurrences(of: "ʔ", with: "t")
                out += ps + tk.whitespace
            }
            return out
        }

        static func subtokenize(_ word: String) -> [String] {
            let ns = word as NSString
            return subtokenRegex.matches(in: word, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
        }

        func retokenize(_ tokens: [Token]) -> [Word] {
            var words: [Word] = []
            var currency: String?
            for (i, token) in tokens.enumerated() {
                var tks: [Token]
                if token.alias == nil && token.phonemes == nil {
                    tks = Self.subtokenize(token.text).map { t in
                        var c = Token(text: t, tag: token.tag, whitespace: "")
                        c.numFlags = token.numFlags
                        c.stress = token.stress
                        return c
                    }
                    if tks.isEmpty { tks = [Token(text: token.text, tag: token.tag, whitespace: "")] }
                } else {
                    tks = [token]
                }
                tks[tks.count - 1].whitespace = token.whitespace
                for j in tks.indices {
                    var tk = tks[j]
                    if tk.alias != nil || tk.phonemes != nil {
                        // already resolved
                    } else if tk.tag == "$" && Lexicon.currencies[tk.text] != nil {
                        currency = tk.text
                        tk.phonemes = ""
                        tk.rating = 4
                    } else if tk.tag == ":" && (tk.text == "-" || tk.text == "–") {
                        tk.phonemes = "—"
                        tk.rating = 3
                    } else if Self.punctTags.contains(tk.tag) && !tk.text.lowercased().unicodeScalars.allSatisfy({ (97...122).contains($0.value) }) {
                        tk.phonemes = Self.punctTagPhonemes[tk.tag] ?? String(tk.text.filter(Self.puncts.contains))
                        tk.rating = 4
                    } else if currency != nil {
                        if tk.tag != "CD" {
                            currency = nil
                        } else if j + 1 == tks.count && (i + 1 == tokens.count || tokens[i + 1].tag != "CD") {
                            tk.currency = currency
                        }
                    } else if 0 < j && j < tks.count - 1 && tk.text == "2",
                              let before = tks[j - 1].text.last, let after = tks[j + 1].text.first,
                              before.isLetter && after.isLetter {
                        tk.alias = "to"
                    }
                    tks[j] = tk
                    if tk.alias != nil || tk.phonemes != nil {
                        words.append(Word(tokens: [tk], isGroup: false))
                    } else if let last = words.last, last.isGroup, last.tokens[last.tokens.count - 1].whitespace.isEmpty {
                        tk.isHead = false
                        words[words.count - 1].tokens.append(tk)
                    } else {
                        words.append(Word(tokens: [tk], isGroup: tk.whitespace.isEmpty))
                    }
                }
            }
            return words.map { $0.isGroup && $0.tokens.count == 1 ? Word(tokens: $0.tokens, isGroup: false) : $0 }
        }

        static func tokenContext(_ ctx: TokenContext, _ ps: String?, _ token: Token) -> TokenContext {
            var vowel = ctx.futureVowel
            if let ps, !ps.isEmpty {
                for c in ps where Stress.vowels.contains(c) || Stress.consonants.contains(c) || nonQuotePuncts.contains(c) {
                    vowel = nonQuotePuncts.contains(c) ? nil : Stress.vowels.contains(c)
                    break
                }
            }
            let futureTo = token.text == "to" || token.text == "To" || (token.text == "TO" && (token.tag == "TO" || token.tag == "IN"))
            return TokenContext(futureVowel: vowel, futureTo: futureTo)
        }

        /// misaki `merge_tokens`.
        static func merge(_ tokens: [Token], unk: String?) -> Token {
            var phonemes: String?
            if let unk {
                var ps = ""
                for tk in tokens {
                    if tk.prespace, let last = ps.last, !last.isWhitespace, tk.phonemes?.isEmpty == false { ps += " " }
                    ps += tk.phonemes ?? unk
                }
                phonemes = ps
            }
            let text = tokens.dropLast().map { $0.text + $0.whitespace }.joined() + tokens[tokens.count - 1].text
            var best = tokens[0]
            var bestWeight = -1
            for tk in tokens {
                let weight = tk.text.reduce(0) { $0 + (String($1) == $1.lowercased() ? 1 : 2) }
                if weight > bestWeight { best = tk; bestWeight = weight }
            }
            var merged = Token(text: text, tag: best.tag, whitespace: tokens[tokens.count - 1].whitespace)
            merged.phonemes = phonemes
            merged.isHead = tokens[0].isHead
            let stresses = Set(tokens.compactMap(\.stress))
            merged.stress = stresses.count == 1 ? stresses.first : nil
            merged.currency = tokens.compactMap(\.currency).max()
            merged.numFlags = String(Set(tokens.flatMap(\.numFlags)).sorted())
            merged.prespace = tokens[0].prespace
            merged.rating = tokens.contains(where: { $0.rating == nil }) ? nil : tokens.compactMap(\.rating).min()
            return merged
        }

        /// misaki `resolve_tokens`: joins a resolved group, with spaces when it mixes letters,
        /// digits and symbols, and keeps only about half the primary stresses inside one word.
        static func resolve(_ tokens: inout [Token]) {
            let text = tokens.dropLast().map { $0.text + $0.whitespace }.joined() + tokens[tokens.count - 1].text
            let classes = Set(text.filter { !subtokenJunks.contains($0) }.map { c -> Int in c.isLetter ? 0 : (Text.isASCIIDigit(c) ? 1 : 2) })
            let prespace = text.contains(" ") || text.contains("/") || classes.count > 1
            for i in tokens.indices {
                if tokens[i].phonemes == nil {
                    if i == tokens.count - 1, tokens[i].text.count == 1, let c = tokens[i].text.first, nonQuotePuncts.contains(c) {
                        tokens[i].phonemes = tokens[i].text
                        tokens[i].rating = 3
                    } else if tokens[i].text.allSatisfy(subtokenJunks.contains) {
                        tokens[i].phonemes = ""
                        tokens[i].rating = 3
                    }
                } else if i > 0 {
                    tokens[i].prespace = prespace
                }
            }
            if prespace { return }
            var indices: [(primary: Bool, weight: Int, index: Int)] = []
            for (i, tk) in tokens.enumerated() {
                if let ps = tk.phonemes, !ps.isEmpty { indices.append((ps.contains(Stress.primary), Stress.weight(ps), i)) }
            }
            if indices.count == 2 && tokens[indices[0].index].text.count == 1 {
                let i = indices[1].index
                tokens[i].phonemes = tokens[i].phonemes.map { Stress.apply($0, -0.5) }
                return
            } else if indices.count < 2 || indices.filter(\.primary).count <= (indices.count + 1) / 2 {
                return
            }
            let sorted = indices.sorted { a, b in
                if a.primary != b.primary { return !a.primary }
                if a.weight != b.weight { return a.weight < b.weight }
                return a.index < b.index
            }
            for entry in sorted.prefix(indices.count / 2) {
                tokens[entry.index].phonemes = tokens[entry.index].phonemes.map { Stress.apply($0, -0.5) }
            }
        }
    }
}
