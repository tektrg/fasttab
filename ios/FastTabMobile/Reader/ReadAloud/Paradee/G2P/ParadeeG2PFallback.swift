import Foundation

extension ParadeeG2P {
    /// Words misaki's dictionaries don't have. misaki (as Kokoro/Paradee run it) asks espeak-ng
    /// here; espeak-ng is GPL, so instead, in order:
    ///
    /// 1. accents folded ("café" → "cafe") and the lexicon asked again;
    /// 2. the word cut at non-letters ("Kosygin-led", "O(n") and each piece read on its own;
    /// 3. a piece: possessive 's, suffixes misaki doesn't strip (-ied, -ier, -ly, -ness, ...),
    ///    common prefixes (re-, un-, over-, ...) or a two-word compound, all against the dictionary;
    /// 4. otherwise learned letter-to-sound rules (`paradee-<accent>-lts`: for each letter, the
    ///    phonemes it most often makes in that spelling context, learned from misaki's own
    ///    dictionaries — see `G2PData/tools/README.md`);
    /// 5. last resort: spell the letters.
    struct Fallback: Sendable {
        let lexicon: Lexicon
        let rules: LexiconStore

        static let maxContext = 3
        /// Context shapes (letters left, letters right) in the order the rules were trained for: contexts
        /// that see both neighbours first, then larger, then more balanced, then more right context.
        static let shapes: [(Int, Int)] = {
            var s: [(Int, Int)] = []
            for k in 0...maxContext { for m in 0...maxContext { s.append((k, m)) } }
            func rank(_ x: (Int, Int)) -> [Int] { [-(min(x.0, 1) + min(x.1, 1)), -(x.0 + x.1), abs(x.0 - x.1), -x.1] }
            return s.sorted { rank($0).lexicographicallyPrecedes(rank($1)) }
        }()

        func phonemes(for token: Token, ctx: TokenContext) -> (String?, Int?) {
            var text = token.text.replacingOccurrences(of: "\u{2018}", with: "'").replacingOccurrences(of: "\u{2019}", with: "'")
            text = text.precomposedStringWithCompatibilityMapping
            let folded = text.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US"))
            if folded != text {
                var retry = token
                retry.text = folded
                let (ps, rating) = lexicon.phonemes(for: retry, ctx: ctx)
                if let ps { return (ps, rating) }
                text = folded
            }
            let parts = Self.pieces(text)
            if parts.count == 1 { return (piece(parts[0], tag: token.tag, ctx: ctx) ?? "", 1) }
            // Join the pieces the way misaki joins a no-space word group (resolve_tokens): run together
            // when it is all letters, spaced when it mixes letters, digits and symbols; one main stress.
            var tokens = parts.map { part -> Token in
                var tk = Token(text: part, tag: token.tag, whitespace: "")
                tk.phonemes = piece(part, tag: token.tag, ctx: ctx) ?? ""
                return tk
            }
            Pipeline.resolve(&tokens)
            return (Pipeline.merge(tokens, unk: "").phonemes ?? "", 1)
        }

        /// Letter runs (with inner apostrophes; split at camelCase and ACRONYMWord boundaries),
        /// digit runs, and single other characters.
        static func pieces(_ text: String) -> [String] {
            var out: [String] = []
            var current = ""
            var kind = 0   // 1 letters, 2 digits
            let chars = Array(text)
            for (i, c) in chars.enumerated() {
                let k = c.isLetter || (c == "'" && kind == 1) ? 1 : (Text.isASCIIDigit(c) || ((c == "," || c == ".") && kind == 2) ? 2 : 0)
                let camel = k == 1 && kind == 1 && c.isUppercase && current != "Mc" && (current.last?.isLowercase == true
                    || (current.last?.isUppercase == true && i + 1 < chars.count && chars[i + 1].isLowercase))
                if k != 0 && k == kind && !camel {
                    current.append(c)
                    continue
                }
                if !current.isEmpty { out.append(current) }
                current = String(c)
                kind = k
                if k == 0 { out.append(current); current = "" }
            }
            if !current.isEmpty { out.append(current) }
            return out.map { $0.hasSuffix("'") && $0.count > 1 && !$0.hasSuffix("s'") ? String($0.dropLast()) : $0 }
        }

        private func piece(_ part: String, tag: String, ctx: TokenContext) -> String? {
            guard let first = part.first else { return nil }
            if Text.isASCIIDigit(first) {
                var number = Token(text: part, tag: "CD", whitespace: "")
                number.isHead = true
                return lexicon.phonemes(for: number, ctx: ctx).0 ?? spell(part)
            }
            if !first.isLetter {
                if let name = Lexicon.symbols[part] { return lexicon.lookup(name, tag: nil, stress: nil, ctx: nil).0 }
                return nil
            }
            var single = Token(text: part, tag: tag, whitespace: "")
            single.isHead = true
            if let ps = lexicon.phonemes(for: single, ctx: ctx).0 { return ps }
            return word(part)
        }

        /// One letters-only word the lexicon doesn't know.
        func word(_ w: String) -> String {
            if let ps = derived(w, depth: 0) { return ps }
            let ascii = w.lowercased().filter { ("a"..."z").contains($0) }
            // No vowel letter ("Ltd", "Mr"): spell it.
            if ascii.contains(where: { "aeiouy".contains($0) }), let ps = letterToSound(ascii), !ps.isEmpty { return ps }
            return spell(w) ?? ""
        }

        private func known(_ w: String) -> String? {
            let lower = w.lowercased()
            guard lower.count >= 2, lexicon.isKnown(lower, tag: nil) else { return nil }
            return lexicon.lookup(lower, tag: nil, stress: nil, ctx: nil).0
        }

        /// Plain lowercase dictionary words only (no names), for compound halves.
        private func commonWord(_ w: String) -> String? {
            switch lexicon.golds.raw(w) ?? lexicon.silvers.raw(w) {
            case .plain(let ps)?: return ps
            case .tagged(let tags)?: return tags["DEFAULT"] ?? nil
            case nil: return nil
            }
        }

        private static let suffixRules: [(suffix: String, stems: [String], us: String, gb: String)] = [
            ("ied", ["y"], "d", "d"), ("ies", ["y"], "z", "z"), ("ier", ["y"], "iəɹ", "ɪə"), ("iest", ["y"], "iᵻst", "ɪɪst"),
            ("ily", ["y"], "əli", "ɪli"), ("iness", ["y"], "inəs", "inəs"), ("ness", [""], "nəs", "nəs"),
            ("ment", [""], "mənt", "mənt"), ("ments", [""], "mənts", "mənts"), ("ly", [""], "li", "li"),
            ("ful", [""], "fəl", "fʊl"), ("less", [""], "ləs", "ləs"), ("ers", ["", "e"], "əɹz", "əz"),
            ("er", ["", "e"], "əɹ", "ə"), ("est", ["", "e"], "ᵻst", "ɪst"), ("ism", [""], "ˌɪzəm", "ˌɪzəm"),
            ("ists", [""], "ɪsts", "ɪsts"), ("ist", [""], "ɪst", "ɪst"), ("able", ["", "e"], "əbᵊl", "əbᵊl"),
            ("ship", [""], "ʃˌɪp", "ʃɪp"), ("hood", [""], "hˌʊd", "hʊd"), ("wise", [""], "wˌIz", "wIz"),
            ("like", [""], "lˌIk", "lIk"), ("ish", [""], "ɪʃ", "ɪʃ"),
        ]
        private static let prefixRules: [(prefix: String, us: String, gb: String)] = [
            ("counter", "kˌWntəɹ", "kˌWntə"), ("under", "ˌʌndəɹ", "ˌʌndə"), ("inter", "ˌɪntəɹ", "ˌɪntə"),
            ("super", "sˌupəɹ", "sˌuːpə"), ("over", "ˌOvəɹ", "ˌQvə"), ("multi", "mˌʌlti", "mˌʌlti"),
            ("anti", "ˌænti", "ˌanti"), ("semi", "sˌɛmi", "sˌɛmi"), ("self", "sˌɛlf", "sˌɛlf"), ("non", "nˌɑn", "nˌɒn"),
            ("pre", "pɹˌi", "pɹˌiː"), ("dis", "dˌɪs", "dˌɪs"), ("mis", "mˌɪs", "mˌɪs"), ("out", "ˌWt", "ˌWt"),
            ("sub", "sˌʌb", "sˌʌb"), ("un", "ˌʌn", "ˌʌn"), ("re", "ɹˌi", "ɹˌiː"), ("co", "kˌO", "kˌQ"),
        ]
        /// Name prefixes read before a stressed rest ("McClellin" → mək + klˈɛlən).
        private static let namePrefixes: [(prefix: String, us: String, gb: String)] = [("mc", "mək", "mək")]

        /// Dictionary-backed guesses: possessive, extra suffixes, prefixes, two-word compounds.
        private func derived(_ w: String, depth: Int) -> String? {
            let lower = w.lowercased()
            if depth > 1 { return nil }
            if lower.hasSuffix("'s") {          // Rowling's → Rowling + z
                let stem = String(w.dropLast(2))
                guard !stem.isEmpty else { return nil }
                return lexicon.s(known(stem) ?? word(stem))
            }
            if lower.hasSuffix("s'") {          // Kosygins' → Kosygins
                let stem = String(w.dropLast())
                return known(stem) ?? word(stem)
            }
            for rule in Self.suffixRules where lower.hasSuffix(rule.suffix) && lower.count > rule.suffix.count + 2 {
                let root = String(lower.dropLast(rule.suffix.count))
                for tail in rule.stems {
                    guard let ps = known(root + tail) else { continue }
                    switch rule.suffix {
                    case "ied": return lexicon.ed(ps)
                    case "ies": return lexicon.s(ps)
                    default:
                        let base = rule.stems == ["y"] && ps.hasSuffix("i") ? String(ps.dropLast()) : ps
                        return base + (lexicon.british ? rule.gb : rule.us)
                    }
                }
            }
            for rule in Self.namePrefixes where lower.hasPrefix(rule.prefix) && lower.count >= rule.prefix.count + 3 {
                let rest = String(lower.dropFirst(rule.prefix.count))
                let ps = known(rest) ?? letterToSound(rest) ?? ""
                return (lexicon.british ? rule.gb : rule.us) + ps
            }
            // Prefixes only on lowercase words: names that merely start like one ("Renard", "Cohen") aren't.
            for rule in Self.prefixRules where w == lower && lower.hasPrefix(rule.prefix) && lower.count >= rule.prefix.count + 3 {
                let rest = String(lower.dropFirst(rule.prefix.count))
                if let ps = known(rest) ?? derived(rest, depth: depth + 1) {
                    return (lexicon.british ? rule.gb : rule.us) + ps
                }
            }
            // Two-word compounds ("northwestern"). Names are rarely compounds ("Hub+bard"), so a
            // capitalized word needs both halves of 4+ letters.
            let chars = Array(lower)
            let minPart = w == lower ? 3 : 4
            if chars.count >= 2 * minPart {
                for cut in stride(from: chars.count - minPart, through: minPart, by: -1) {
                    let head = String(chars[..<cut]), tail = String(chars[cut...])
                    guard let a = commonWord(head), var b = commonWord(tail) ?? (depth == 0 ? derived(tail, depth: depth + 1) : nil) else { continue }
                    // One sound for a doubled letter across the join ("bookkeeper").
                    if let last = a.last, let first = b.unicodeScalars.first(where: { !"ˈˌ".unicodeScalars.contains($0) }),
                       Character(first) == last, Stress.consonants.contains(last) {
                        b.remove(at: b.firstIndex(of: last)!)
                    }
                    // English compounds stress the first part: demote the second part's primary stress.
                    return a + Stress.apply(b, -0.5)
                }
            }
            return nil
        }

        /// Learned rules: for each letter, the longest context the table knows decides its phonemes.
        func letterToSound(_ w: String) -> String? {
            guard !w.isEmpty, rules.count > 0 else { return nil }
            let pad = String(repeating: "#", count: Self.maxContext)
            let padded = Array(pad + w + pad)
            func chunk(_ p: Int, shapes: [(Int, Int)]) -> String {
                for (k, m) in shapes {
                    let key = String(padded[(p - k)..<p]) + "(" + String(padded[p]) + ")" + String(padded[(p + 1)..<(p + 1 + m)])
                    if case .plain(let chunk)? = rules.raw(key) { return chunk == "_" ? "" : chunk }
                }
                return ""
            }
            var parts = (0..<w.count).map { chunk($0 + Self.maxContext, shapes: Self.shapes) }
            if !parts.joined().contains(where: Stress.vowels.contains) {
                // No vowel came out ("fehr" → fɹ): give each vowel letter its context-free sound.
                for (i, letter) in w.enumerated() where "aeiouy".contains(letter) && !parts[i].contains(where: Stress.vowels.contains) {
                    parts[i] = chunk(i + Self.maxContext, shapes: [(0, 0)]) + parts[i]
                }
            }
            return Self.fixStress(parts.joined())
        }

        /// Exactly one stress mark, a primary: the first primary the rules produced, else the first
        /// secondary, else the first vowel. (Secondary stresses guessed letter by letter were wrong
        /// more often than right on held-out words.)
        static func fixStress(_ ps: String) -> String {
            let target = ps.firstIndex(of: Stress.primary) ?? ps.firstIndex(of: Stress.secondary)
            var out = ""
            var placed = false
            for i in ps.indices {
                let c = ps[i]
                if c == Stress.primary || c == Stress.secondary {
                    if i == target { out.append(Stress.primary); placed = true }
                    continue
                }
                if !placed && target == nil && Stress.vowels.contains(c) { out.append(Stress.primary); placed = true }
                out.append(c)
            }
            return out
        }

        func spell(_ w: String) -> String? {
            lexicon.getNNP(w).0
        }
    }
}
