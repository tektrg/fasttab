import Foundation

// Port of misaki's `en.Lexicon` (https://github.com/hexgrad/misaki, misaki/en.py, Apache 2.0):
// gold → silver dictionary lookup, misaki's special cases, stress rules, -s/-ed/-ing stems and
// number reading. Method names and branch order follow the Python so the two can be diffed.

extension ParadeeG2P {
    /// One dictionary value: a plain reading, or readings keyed by POS tag (heteronyms,
    /// e.g. "read" → DEFAULT ɹˈid / VBD ɹˈɛd). A nil reading means "no reading, spell it".
    enum Entry: Sendable {
        case plain(String)
        case tagged([String: String?])
    }

    /// A misaki dictionary (gold or silver) as one sorted UTF-8 blob of `key\tvalue\n` lines,
    /// binary-searched in place: no per-entry allocation, ~4.5 MB resident per accent.
    struct LexiconStore: Sendable {
        private let bytes: [UInt8]
        private let lineStarts: [Int32]

        static let empty = LexiconStore(bytes: [])

        init(bytes: [UInt8]) {
            self.bytes = bytes
            var starts: [Int32] = []
            starts.reserveCapacity(bytes.count / 20)
            var lineStart = 0
            for (i, b) in bytes.enumerated() where b == 0x0A {
                if i > lineStart { starts.append(Int32(lineStart)) }
                lineStart = i + 1
            }
            if lineStart < bytes.count { starts.append(Int32(lineStart)) }
            self.lineStarts = starts
        }

        var count: Int { lineStarts.count }

        /// Exact key lookup (no case growing).
        func raw(_ key: String) -> Entry? {
            let query = Array(key.utf8)
            guard !query.isEmpty, !lineStarts.isEmpty else { return nil }
            return bytes.withUnsafeBufferPointer { buf -> Entry? in
                var lo = 0, hi = lineStarts.count - 1
                while lo <= hi {
                    let mid = (lo + hi) / 2
                    let start = Int(lineStarts[mid])
                    let c = Self.compare(buf, start, query)
                    if c == 0 {
                        return Self.value(buf, start + query.count + 1)
                    } else if c < 0 {
                        lo = mid + 1
                    } else {
                        hi = mid - 1
                    }
                }
                return nil
            }
        }

        /// misaki's `grow_dictionary`: a lowercase key also answers for its Capitalized form and a
        /// Capitalized key for its lowercase form (keys of 2+ characters; exact keys win).
        func get(_ word: String) -> Entry? {
            if let hit = raw(word) { return hit }
            guard word.count >= 2 else { return nil }
            let lower = word.lowercased()
            if word == lower {
                let cap = Text.capitalize(word)
                if cap != word { return raw(cap) }
            } else if word == Text.capitalize(lower) {
                return raw(lower)
            }
            return nil
        }

        func contains(_ word: String) -> Bool { get(word) != nil }

        /// Keys whose value is POS-keyed (heteronyms such as "read", "live", "record").
        func taggedKeys() -> Set<String> {
            var keys: Set<String> = []
            bytes.withUnsafeBufferPointer { buf in
                for start in lineStarts {
                    var tab = Int(start)
                    while tab < buf.count && buf[tab] != 0x09 { tab += 1 }
                    if tab + 1 < buf.count && buf[tab + 1] == UInt8(ascii: "{") {
                        keys.insert(String(decoding: UnsafeBufferPointer(rebasing: buf[Int(start)..<tab]), as: UTF8.self))
                    }
                }
            }
            return keys
        }

        /// Compares the key of the line at `start` (bytes up to the tab) with `query`.
        private static func compare(_ buf: UnsafeBufferPointer<UInt8>, _ start: Int, _ query: [UInt8]) -> Int {
            var i = start, j = 0
            while true {
                let kb: UInt8 = i < buf.count ? buf[i] : 0x09
                let keyEnded = kb == 0x09
                let queryEnded = j == query.count
                if keyEnded && queryEnded { return 0 }
                if keyEnded { return -1 }
                if queryEnded { return 1 }
                let qb = query[j]
                if kb != qb { return kb < qb ? -1 : 1 }
                i += 1; j += 1
            }
        }

        private static func value(_ buf: UnsafeBufferPointer<UInt8>, _ start: Int) -> Entry {
            var end = start
            while end < buf.count && buf[end] != 0x0A { end += 1 }
            let text = String(decoding: UnsafeBufferPointer(rebasing: buf[start..<end]), as: UTF8.self)
            guard text.hasPrefix("{"), text.hasSuffix("}") else { return .plain(text) }
            var tags: [String: String?] = [:]
            for part in text.dropFirst().dropLast().split(separator: "|") {
                guard let eq = part.firstIndex(of: "=") else { continue }
                let reading = part[part.index(after: eq)...]
                tags[String(part[..<eq])] = reading.isEmpty ? String?.none : String(reading)
            }
            return .tagged(tags)
        }
    }

    /// What misaki calls `TokenContext`: facts about the words to the right (the text is
    /// processed right to left). `futureVowel` is nil when punctuation or the end comes next.
    struct TokenContext {
        var futureVowel: Bool?
        var futureTo = false
    }

    /// misaki's `Lexicon` for one accent.
    struct Lexicon: Sendable {
        let british: Bool
        let golds: LexiconStore
        let silvers: LexiconStore

        static let capStresses: (Double, Double) = (0.5, 2)
        static let currencies: [String: (String, String)] = ["$": ("dollar", "cent"), "£": ("pound", "pence"), "€": ("euro", "cent")]
        static let ordinals: Set<String> = ["st", "nd", "rd", "th"]
        static let addSymbols: [String: String] = [".": "dot", "/": "slash"]
        static let symbols: [String: String] = ["%": "percent", "&": "and", "+": "plus", "@": "at"]
        static let usTaus: Set<Character> = Set("AIOWYiuæɑəɛɪɹʊʌ")

        // MARK: Entry points

        /// misaki `Lexicon.__call__`.
        func phonemes(for tk: Token, ctx: TokenContext) -> (String?, Int?) {
            var word = (tk.alias ?? tk.text).replacingOccurrences(of: "\u{2018}", with: "'").replacingOccurrences(of: "\u{2019}", with: "'")
            word = word.precomposedStringWithCompatibilityMapping
            word = String(word.map(Text.numericIfNeeded).joined())
            let stress: Double? = word == word.lowercased() ? nil : (word == word.uppercased() ? Self.capStresses.1 : Self.capStresses.0)
            let (ps, rating) = getWord(word, tag: tk.tag, stress: stress, ctx: ctx)
            if let ps {
                return (Stress.apply(appendCurrency(ps, tk.currency), tk.stress), rating)
            } else if Self.isNumber(word, isHead: tk.isHead) {
                let (ps, rating) = getNumber(word, currency: tk.currency, isHead: tk.isHead, numFlags: tk.numFlags)
                return (ps.map { Stress.apply($0, tk.stress) }, rating)
            }
            return (nil, nil)
        }

        // MARK: Lookup

        func getNNP(_ word: String) -> (String?, Int?) {
            var parts: [String] = []
            for c in word where c.isLetter {
                guard case .plain(let ps)? = golds.get(String(c).uppercased()) else { return (nil, nil) }
                parts.append(ps)
            }
            let ps = Stress.apply(parts.joined(), 0)
            guard let range = ps.range(of: String(Stress.secondary), options: .backwards) else { return (ps, 3) }
            return (ps.replacingCharacters(in: range, with: String(Stress.primary)), 3)
        }

        func getSpecialCase(_ word: String, tag: String, stress: Double?, ctx: TokenContext) -> (String?, Int?) {
            if tag == "ADD", let name = Self.addSymbols[word] {
                return lookup(name, tag: nil, stress: -0.5, ctx: ctx)
            } else if let name = Self.symbols[word] {
                return lookup(name, tag: nil, stress: nil, ctx: ctx)
            } else if Text.strip(word, ".").contains("."), Text.isAlpha(word.replacingOccurrences(of: ".", with: "")),
                      (word.split(separator: ".", omittingEmptySubsequences: false).map(\.count).max() ?? 0) < 3 {
                return getNNP(word)
            } else if word == "a" || word == "A" {
                return (tag == "DT" ? "ɐ" : "ˈA", 4)
            } else if ["am", "Am", "AM"].contains(word) {
                if tag.hasPrefix("NN") {
                    return getNNP(word)
                } else if ctx.futureVowel == nil || word != "am" || (stress ?? 0) > 0 {
                    if case .plain(let ps)? = golds.get("am") { return (ps, 4) }
                }
                return ("ɐm", 4)
            } else if ["an", "An", "AN"].contains(word) {
                if word == "AN" && tag.hasPrefix("NN") { return getNNP(word) }
                return ("ɐn", 4)
            } else if word == "I" && tag == "PRP" {
                return ("\(Stress.secondary)I", 4)
            } else if ["by", "By", "BY"].contains(word) && Self.parentTag(tag) == "ADV" {
                return ("bˈI", 4)
            } else if word == "to" || word == "To" || (word == "TO" && (tag == "TO" || tag == "IN")) {
                switch ctx.futureVowel {
                case nil: if case .plain(let ps)? = golds.get("to") { return (ps, 4) }; return ("tu", 4)
                case false?: return ("tə", 4)
                case true?: return ("tʊ", 4)
                }
            } else if word == "in" || word == "In" || (word == "IN" && tag != "NNP") {
                let mark = ctx.futureVowel == nil || tag != "IN" ? String(Stress.primary) : ""
                return (mark + "ɪn", 4)
            } else if word == "the" || word == "The" || (word == "THE" && tag == "DT") {
                return (ctx.futureVowel == true ? "ði" : "ðə", 4)
            } else if tag == "IN", word.range(of: #"^(?i)vs\.?$"#, options: .regularExpression) != nil {
                return lookup("versus", tag: nil, stress: nil, ctx: ctx)
            } else if ["used", "Used", "USED"].contains(word) {
                if case .tagged(let tags)? = golds.get("used") {
                    if (tag == "VBD" || tag == "JJ") && ctx.futureTo { return ((tags["VBD"] ?? nil), 4) }
                    return ((tags["DEFAULT"] ?? nil), 4)
                }
            }
            return (nil, nil)
        }

        static func parentTag(_ tag: String?) -> String? {
            guard let tag else { return nil }
            if tag.hasPrefix("VB") { return "VERB" }
            if tag.hasPrefix("NN") { return "NOUN" }
            if tag.hasPrefix("ADV") || tag.hasPrefix("RB") { return "ADV" }
            if tag.hasPrefix("ADJ") || tag.hasPrefix("JJ") { return "ADJ" }
            return tag
        }

        func isKnown(_ word: String, tag: String?) -> Bool {
            if golds.contains(word) || Self.symbols[word] != nil || silvers.contains(word) {
                return true
            } else if !Text.isAlpha(word) || !word.unicodeScalars.allSatisfy(Text.isLexiconScalar) {
                return false
            } else if word.count == 1 {
                return true
            } else if word == word.uppercased() && golds.contains(word.lowercased()) {
                return true
            }
            let rest = word.dropFirst()
            return rest == rest.uppercased()[...]
        }

        func lookup(_ word0: String, tag tag0: String?, stress: Double?, ctx: TokenContext?) -> (String?, Int?) {
            var word = word0
            var tag = tag0
            var isNNP: Bool?
            if word == word.uppercased() && !golds.contains(word) {
                word = word.lowercased()
                isNNP = tag == "NNP"
            }
            var entry = golds.get(word)
            var rating = 4
            if entry == nil && isNNP != true {
                entry = silvers.get(word)
                rating = 3
            }
            var ps: String?
            switch entry {
            case .plain(let reading)?:
                ps = reading
            case .tagged(let tags)?:
                if let ctx, ctx.futureVowel == nil, tags["None"] != nil {
                    tag = "None"
                } else if tag == nil || tags[tag!] == nil {
                    tag = Self.parentTag(tag)
                }
                if let tag, let reading = tags[tag] { ps = reading } else { ps = tags["DEFAULT"] ?? nil }
            case nil:
                ps = nil
            }
            if ps == nil || (isNNP == true && !ps!.contains(Stress.primary)) {
                let (nnp, nnpRating) = getNNP(word)
                if nnp != nil { return (nnp, nnpRating) }
            }
            return (ps.map { Stress.apply($0, stress) }, rating)
        }

        // MARK: Suffixes

        func s(_ stem: String?) -> String? {
            guard let stem, let last = stem.last else { return nil }
            if "ptkfθ".contains(last) { return stem + "s" }
            if "szʃʒʧʤ".contains(last) { return stem + (british ? "ɪ" : "ᵻ") + "z" }
            return stem + "z"
        }

        func stemS(_ word: String, tag: String?, stress: Double?, ctx: TokenContext?) -> (String?, Int?) {
            guard word.count >= 3, word.hasSuffix("s") else { return (nil, nil) }
            let stem: String
            if !word.hasSuffix("ss") && isKnown(String(word.dropLast()), tag: tag) {
                stem = String(word.dropLast())
            } else if (word.hasSuffix("'s") || (word.count > 4 && word.hasSuffix("es") && !word.hasSuffix("ies"))) && isKnown(String(word.dropLast(2)), tag: tag) {
                stem = String(word.dropLast(2))
            } else if word.count > 4 && word.hasSuffix("ies") && isKnown(String(word.dropLast(3)) + "y", tag: tag) {
                stem = String(word.dropLast(3)) + "y"
            } else {
                return (nil, nil)
            }
            let (ps, rating) = lookup(stem, tag: tag, stress: stress, ctx: ctx)
            return (s(ps), rating)
        }

        func ed(_ stem: String?) -> String? {
            guard let stem, let last = stem.last else { return nil }
            if "pkfθʃsʧ".contains(last) { return stem + "t" }
            if last == "d" { return stem + (british ? "ɪ" : "ᵻ") + "d" }
            if last != "t" { return stem + "d" }
            if british || stem.count < 2 { return stem + "ɪd" }
            if Self.usTaus.contains(stem[stem.index(stem.endIndex, offsetBy: -2)]) { return String(stem.dropLast()) + "ɾᵻd" }
            return stem + "ᵻd"
        }

        func stemEd(_ word: String, tag: String?, stress: Double?, ctx: TokenContext?) -> (String?, Int?) {
            guard word.count >= 4, word.hasSuffix("d") else { return (nil, nil) }
            let stem: String
            if !word.hasSuffix("dd") && isKnown(String(word.dropLast()), tag: tag) {
                stem = String(word.dropLast())
            } else if word.count > 4 && word.hasSuffix("ed") && !word.hasSuffix("eed") && isKnown(String(word.dropLast(2)), tag: tag) {
                stem = String(word.dropLast(2))
            } else {
                return (nil, nil)
            }
            let (ps, rating) = lookup(stem, tag: tag, stress: stress, ctx: ctx)
            return (ed(ps), rating)
        }

        func ing(_ stem: String?) -> String? {
            guard let stem, let last = stem.last else { return nil }
            if british {
                if last == "ə" || last == "ː" { return nil }
            } else if stem.count > 1 && last == "t" && Self.usTaus.contains(stem[stem.index(stem.endIndex, offsetBy: -2)]) {
                return String(stem.dropLast()) + "ɾɪŋ"
            }
            return stem + "ɪŋ"
        }

        func stemIng(_ word: String, tag: String?, stress: Double?, ctx: TokenContext?) -> (String?, Int?) {
            guard word.count >= 5, word.hasSuffix("ing") else { return (nil, nil) }
            let base = String(word.dropLast(3))
            let stem: String
            if word.count > 5 && isKnown(base, tag: tag) {
                stem = base
            } else if isKnown(base + "e", tag: tag) {
                stem = base + "e"
            } else if word.count > 5, word.range(of: #"([bcdgklmnprstvxz])\1ing$|cking$"#, options: .regularExpression) != nil,
                      isKnown(String(word.dropLast(4)), tag: tag) {
                stem = String(word.dropLast(4))
            } else {
                return (nil, nil)
            }
            let (ps, rating) = lookup(stem, tag: tag, stress: stress, ctx: ctx)
            return (ing(ps), rating)
        }

        func getWord(_ word0: String, tag: String, stress: Double?, ctx: TokenContext) -> (String?, Int?) {
            let special = getSpecialCase(word0, tag: tag, stress: stress, ctx: ctx)
            if special.0 != nil { return special }
            var word = word0
            let wl = word.lowercased()
            if word.count > 1, Text.isAlpha(word.replacingOccurrences(of: "'", with: "")), word != wl,
               tag != "NNP" || word.count > 7,
               !golds.contains(word), !silvers.contains(word),
               word == word.uppercased() || word.dropFirst() == wl.dropFirst(),
               golds.contains(wl) || silvers.contains(wl)
                || stemS(wl, tag: tag, stress: stress, ctx: ctx).0 != nil
                || stemEd(wl, tag: tag, stress: stress, ctx: ctx).0 != nil
                || stemIng(wl, tag: tag, stress: stress, ctx: ctx).0 != nil {
                word = wl
            }
            if isKnown(word, tag: tag) {
                return lookup(word, tag: tag, stress: stress, ctx: ctx)
            } else if word.hasSuffix("s'") && isKnown(String(word.dropLast(2)) + "'s", tag: tag) {
                return lookup(String(word.dropLast(2)) + "'s", tag: tag, stress: stress, ctx: ctx)
            } else if word.hasSuffix("'") && isKnown(String(word.dropLast()), tag: tag) {
                return lookup(String(word.dropLast()), tag: tag, stress: stress, ctx: ctx)
            }
            let sForm = stemS(word, tag: tag, stress: stress, ctx: ctx)
            if sForm.0 != nil { return sForm }
            let edForm = stemEd(word, tag: tag, stress: stress, ctx: ctx)
            if edForm.0 != nil { return edForm }
            let ingForm = stemIng(word, tag: tag, stress: stress ?? 0.5, ctx: ctx)
            if ingForm.0 != nil { return ingForm }
            return (nil, nil)
        }

        // MARK: Numbers

        static func isCurrency(_ word: String) -> Bool {
            guard word.contains(".") else { return true }
            let parts = word.split(separator: ".", omittingEmptySubsequences: false)
            if parts.count > 2 { return false }
            return parts[1].count < 3
        }

        static func isNumber(_ word0: String, isHead: Bool) -> Bool {
            guard word0.contains(where: Text.isASCIIDigit) else { return false }
            var word = Substring(word0)
            for suffix in ["ing", "'d", "ed", "'s", "st", "nd", "rd", "th", "s"] where word.hasSuffix(suffix) {
                word = word.dropLast(suffix.count)
                break
            }
            for (i, c) in word.enumerated() where !(Text.isASCIIDigit(c) || c == "," || c == "." || (isHead && i == 0 && c == "-")) {
                return false
            }
            return true
        }

        func getNumber(_ word0: String, currency: String?, isHead: Bool, numFlags: String) -> (String?, Int?) {
            var word = word0
            var suffix: String?
            if let r = word.range(of: #"[a-z']+$"#, options: .regularExpression) {
                suffix = String(word[r])
                word = String(word[..<r.lowerBound])
            }
            var result: [(String?, Int?)] = []
            if word.hasPrefix("-") {
                result.append(lookup("minus", tag: nil, stress: nil, ctx: nil))
                word.removeFirst()
            }
            func extendNum(_ num: String, first: Bool = true, escape: Bool = false) {
                let text = escape ? num : NumberWords.cardinal(Int(num) ?? 0)
                let splits = text.split(whereSeparator: { !("a"..."z").contains($0) }).map(String.init)
                for (i, w) in splits.enumerated() {
                    if w != "and" || numFlags.contains("&") {
                        if first && i == 0 && splits.count > 1 && w == "one" && numFlags.contains("a") {
                            result.append(("ə", 4))
                        } else {
                            result.append(lookup(w, tag: nil, stress: w == "point" ? -2 : nil, ctx: nil))
                        }
                    } else if w == "and" && numFlags.contains("n"), let last = result.last {
                        result[result.count - 1] = ((last.0 ?? "") + "ən", last.1)
                    }
                }
            }
            func eachDigit(_ num: String) { for d in num { extendNum(String(d), first: false) } }

            if Text.isDigits(word), let suffix, Self.ordinals.contains(suffix) {
                extendNum(NumberWords.ordinal(Int(word) ?? 0), escape: true)
            } else if result.isEmpty && word.count == 4 && (currency == nil || Self.currencies[currency!] == nil) && Text.isDigits(word) {
                extendNum(NumberWords.year(Int(word) ?? 0), escape: true)
            } else if !isHead && !word.contains(".") {
                let num = word.replacingOccurrences(of: ",", with: "")
                let chars = Array(num)
                if chars.first == "0" || chars.count > 3 {
                    eachDigit(num)
                } else if chars.count == 3 && !num.hasSuffix("00") {
                    extendNum(String(chars[0]))
                    if chars[1] == "0" {
                        result.append(lookup("O", tag: nil, stress: -2, ctx: nil))
                        extendNum(String(chars[2]), first: false)
                    } else {
                        extendNum(String(chars[1...]), first: false)
                    }
                } else if !chars.isEmpty {
                    extendNum(num)
                }
            } else if word.filter({ $0 == "." }).count > 1 || !isHead {
                var first = true
                for num in word.replacingOccurrences(of: ",", with: "").split(separator: ".", omittingEmptySubsequences: false).map(String.init) {
                    if num.isEmpty {
                        // nothing
                    } else if num.first == "0" || (num.count != 2 && num.dropFirst().contains(where: { $0 != "0" })) {
                        eachDigit(num)
                    } else {
                        extendNum(num, first: first)
                    }
                    first = false
                }
            } else if let currency, let units = Self.currencies[currency], Self.isCurrency(word) {
                let amounts = word.replacingOccurrences(of: ",", with: "").split(separator: ".", omittingEmptySubsequences: false)
                var pairs: [(Int, String)] = zip(amounts, [units.0, units.1]).map { (Int($0.0) ?? 0, $0.1) }
                if pairs.count > 1 {
                    if pairs[1].0 == 0 { pairs = Array(pairs.prefix(1)) } else if pairs[0].0 == 0 { pairs = Array(pairs.dropFirst()) }
                }
                for (i, pair) in pairs.enumerated() {
                    if i > 0 { result.append(lookup("and", tag: nil, stress: nil, ctx: nil)) }
                    extendNum(String(pair.0), first: i == 0)
                    result.append(abs(pair.0) != 1 && pair.1 != "pence"
                                  ? stemS(pair.1 + "s", tag: nil, stress: nil, ctx: nil)
                                  : lookup(pair.1, tag: nil, stress: nil, ctx: nil))
                }
            } else {
                var text: String
                if Text.isDigits(word) {
                    text = NumberWords.cardinal(Int(word) ?? 0)
                } else if !word.contains(".") {
                    let n = Int(word.replacingOccurrences(of: ",", with: "")) ?? 0
                    text = suffix.map(Self.ordinals.contains) == true ? NumberWords.ordinal(n) : NumberWords.cardinal(n)
                } else {
                    let plain = word.replacingOccurrences(of: ",", with: "")
                    if plain.hasPrefix(".") {
                        text = "point " + plain.dropFirst().map { NumberWords.cardinal(Int(String($0)) ?? 0) }.joined(separator: " ")
                    } else {
                        text = NumberWords.decimal(plain)
                    }
                }
                extendNum(text, escape: true)
            }
            guard !result.isEmpty, result.allSatisfy({ $0.0 != nil }) else { return (nil, nil) }
            let joined = result.map { $0.0! }.joined(separator: " ")
            let rating = result.compactMap(\.1).min()
            if suffix == "s" || suffix == "'s" { return (s(joined), rating) }
            if suffix == "ed" || suffix == "'d" { return (ed(joined), rating) }
            if suffix == "ing" { return (ing(joined), rating) }
            return (joined, rating)
        }

        func appendCurrency(_ ps: String, _ currency: String?) -> String {
            guard let currency, let units = Self.currencies[currency], let name = stemS(units.0 + "s", tag: nil, stress: nil, ctx: nil).0 else { return ps }
            return "\(ps) \(name)"
        }
    }

    /// misaki's stress helpers (`apply_stress`, `stress_weight`).
    enum Stress {
        static let primary: Character = "ˈ"
        static let secondary: Character = "ˌ"
        static let vowels: Set<Character> = Set("AIOQWYaiuæɑɒɔəɛɜɪʊʌᵻ")
        static let consonants: Set<Character> = Set("bdfhjklmnpstvwzðŋɡɹɾʃʒʤʧθ")
        static let diphthongs: Set<Character> = Set("AIOQWYʤʧ")

        static func weight(_ ps: String?) -> Int {
            guard let ps else { return 0 }
            return ps.reduce(0) { $0 + (diphthongs.contains($1) ? 2 : 1) }
        }

        /// Puts `mark` just before the first vowel (misaki's `restress` of `mark + ps`).
        private static func restress(_ mark: Character, _ ps: String) -> String {
            guard let i = ps.firstIndex(where: vowels.contains) else { return ps }
            var out = ps
            out.insert(mark, at: i)
            return out
        }

        static func apply(_ ps: String, _ stress: Double?) -> String {
            guard let stress else { return ps }
            let hasPrimary = ps.contains(primary), hasSecondary = ps.contains(secondary)
            if stress < -1 {
                return ps.replacingOccurrences(of: String(primary), with: "").replacingOccurrences(of: String(secondary), with: "")
            } else if stress == -1 || ((stress == 0 || stress == -0.5) && hasPrimary) {
                return ps.replacingOccurrences(of: String(secondary), with: "").replacingOccurrences(of: String(primary), with: String(secondary))
            } else if (stress == 0 || stress == 0.5 || stress == 1) && !hasPrimary && !hasSecondary {
                if !ps.contains(where: vowels.contains) { return ps }
                return restress(secondary, ps)
            } else if stress >= 1 && !hasPrimary && hasSecondary {
                return ps.replacingOccurrences(of: String(secondary), with: String(primary))
            } else if stress > 1 && !hasPrimary && !hasSecondary {
                if !ps.contains(where: vowels.contains) { return ps }
                return restress(primary, ps)
            }
            return ps
        }
    }

    /// Python string predicates the port relies on (`isalpha`, `capitalize`, `strip`, ...).
    enum Text {
        static func isAlpha(_ s: some StringProtocol) -> Bool { !s.isEmpty && s.allSatisfy(\.isLetter) }
        static func isASCIIDigit(_ c: Character) -> Bool { c.isASCII && c.isNumber }
        static func isDigits(_ s: some StringProtocol) -> Bool { !s.isEmpty && s.allSatisfy(isASCIIDigit) }
        /// misaki LEXICON_ORDS: ' - A-Z a-z.
        static func isLexiconScalar(_ u: Unicode.Scalar) -> Bool {
            u == "'" || u == "-" || ("A"..."Z").contains(u) || ("a"..."z").contains(u)
        }
        static func capitalize(_ s: String) -> String {
            guard let first = s.first else { return s }
            return first.uppercased() + s.dropFirst().lowercased()
        }
        static func strip(_ s: String, _ chars: Character) -> Substring {
            var sub = Substring(s)
            while sub.first == chars { sub = sub.dropFirst() }
            while sub.last == chars { sub = sub.dropLast() }
            return sub
        }
        /// misaki `numeric_if_needed`: non-ASCII digits (², ٣) become their ASCII value.
        static func numericIfNeeded(_ c: Character) -> String {
            guard !c.isASCII, c.unicodeScalars.count == 1, let u = c.unicodeScalars.first,
                  u.properties.numericType == .decimal || u.properties.numericType == .digit,
                  let v = c.wholeNumberValue else { return String(c) }
            return String(v)
        }
    }
}
