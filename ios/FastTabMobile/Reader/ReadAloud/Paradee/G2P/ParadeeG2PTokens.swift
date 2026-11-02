import Foundation

// misaki runs spaCy (en_core_web_sm) first: its tokenizer splits text into tokens and its tagger
// gives each a Penn Treebank tag. We can't ship spaCy, so this file reproduces the tokenizer's
// prefix/suffix/infix rules for English and replaces the statistical tagger with a small rule
// tagger that only decides what misaki's lexicon actually looks at: punctuation tags, CD/$ for
// currency, DT/PRP/IN/TO for function words, NNP for names and all-caps, and VERB/NOUN/ADJ for
// the ~790 heteronyms (read, live, record, ...).

extension ParadeeG2P {
    /// misaki's `MToken` (text, tag, whitespace, phonemes + the `_` extension fields).
    struct Token: Sendable {
        var text: String
        var tag: String
        var whitespace: String
        var phonemes: String?
        var isHead = true
        var alias: String?
        var stress: Double?
        var currency: String?
        var numFlags = ""
        var prespace = false
        var rating: Int?

        init(text: String, tag: String, whitespace: String) {
            self.text = text
            self.tag = tag
            self.whitespace = whitespace
        }
    }

    enum Tokenizer {
        // MARK: spaCy's English tokenizer

        /// Where a piece came from inside its whitespace-separated chunk (quotes use it to tell open from close).
        enum Side { case prefix, core, suffix, alone }

        struct Piece {
            var text: String
            var whitespace: String
            var side: Side
            /// For infix pieces: the characters around them inside the chunk.
            var before: Character?
            var after: Character?
        }

        /// spaCy tokenizer exceptions that keep a trailing period (abbreviations), English only.
        static let specials: Set<String> = [
            "10a.m.", "10p.m.", "11a.m.", "11p.m.", "12a.m.", "12p.m.", "1a.m.", "1p.m.", "2a.m.", "2p.m.", "3a.m.", "3p.m.",
            "4a.m.", "4p.m.", "5a.m.", "5p.m.", "6a.m.", "6p.m.", "7a.m.", "7p.m.", "8a.m.", "8p.m.", "9a.m.", "9p.m.",
            "Adm.", "Ak.", "Ala.", "Apr.", "Ariz.", "Ark.", "Aug.", "Bros.", "Calif.", "Co.", "Colo.", "Conn.", "Corp.", "D.C.",
            "Dec.", "Del.", "Dr.", "E.G.", "E.g.", "Feb.", "Fla.", "Ga.", "Gen.", "Gov.", "I.E.", "I.e.", "Ia.", "Id.", "Ill.",
            "Inc.", "Ind.", "Jan.", "Jr.", "Jul.", "Jun.", "Kan.", "Kans.", "Ky.", "La.", "Ltd.", "Mar.", "Mass.", "Md.",
            "Messrs.", "Mich.", "Minn.", "Miss.", "Mo.", "Mont.", "Mr.", "Mrs.", "Ms.", "Mt.", "N.C.", "N.D.", "N.H.", "N.J.",
            "N.M.", "N.Y.", "Neb.", "Nebr.", "Nev.", "Nov.", "Oct.", "Okla.", "Ore.", "Pa.", "Ph.D.", "Prof.", "Rep.", "Rev.",
            "S.C.", "Sen.", "Sep.", "Sept.", "St.", "Tenn.", "Va.", "Wash.", "Wis.", "a.", "a.m.", "b.", "c.", "co.", "d.",
            "e.", "e.g.", "f.", "g.", "h.", "i.", "i.e.", "j.", "k.", "l.", "m.", "n.", "o.", "p.", "p.m.", "q.", "r.", "s.",
            "t.", "u.", "v.", "v.s.", "vs.", "w.", "x.", "y.", "z.",
            // Clitics written apart ("They 'll", "I 'm") stay whole, as spaCy's exceptions keep them.
            "'s", "'S", "'m", "'M", "'d", "'D", "'ll", "'LL", "'re", "'RE", "'ve", "'VE", "n't", "N'T",
            "’s", "’m", "’d", "’ll", "’re", "’ve", "n’t",
        ]

        private static let affixChars: Set<Character> = Set("…,:;!?¿¡()[]{}<>_#*&'\"”“`‘´’‚„»«")
        private static let prefixOnly: Set<Character> = Set("§%=—–$£€¥฿₽₹₩₪₫₱₴₺")
        private static let currencySymbols: Set<String> = ["$", "£", "€", "¥", "฿", "US$", "C$", "A$", "₽", "₹", "₩", "₪", "₫", "₱", "₴", "₺"]
        private static let units: Set<String> = [
            "km", "km²", "km³", "m", "m²", "m³", "dm", "dm²", "dm³", "cm", "cm²", "cm³", "mm", "mm²", "mm³", "ha", "µm", "nm",
            "yd", "in", "ft", "kg", "g", "mg", "µg", "t", "lb", "oz", "m/s", "km/h", "kmh", "mph", "hPa", "Pa", "mbar", "mb",
            "MB", "kb", "KB", "gb", "GB", "tb", "TB", "T", "G", "M", "K", "%",
        ]
        private static let quoteChars: Set<Character> = Set("'\"”“`‘´’‚,„»«")
        /// spaCy's PUNCT class (a period after one of these is split off too).
        private static let punctChars: Set<Character> = Set("…,:;!?¿¡()[]{}<>_#*&。？！，、；：～·")

        private static func isSymbol(_ c: Character) -> Bool {
            guard let u = c.unicodeScalars.first else { return false }
            return u.properties.generalCategory == .otherSymbol
        }

        static func split(_ text: String) -> [Piece] {
            let chunks = text.split(whereSeparator: \.isWhitespace).map(String.init)
            var pieces: [Piece] = []
            for (i, chunk) in chunks.enumerated() {
                let nextStartsWithDigit = i + 1 < chunks.count && chunks[i + 1].first.map(Text.isASCIIDigit) == true
                var parts = splitChunk(chunk, keepNumberAbbreviation: nextStartsWithDigit)
                if parts.count == 1 { parts[0].side = .alone }
                if !parts.isEmpty { parts[parts.count - 1].whitespace = i + 1 < chunks.count ? " " : "" }
                pieces.append(contentsOf: parts)
            }
            return pieces
        }

        private static func prefixLength(_ s: String) -> Int {
            guard let c = s.first else { return 0 }
            if s.hasPrefix("..") { return s.prefix(while: { $0 == "." }).count }
            if s.hasPrefix("US$") { return 3 }
            if s.hasPrefix("C$") || s.hasPrefix("A$") { return 2 }
            if c == "+" { return s.dropFirst().first.map(Text.isASCIIDigit) == true ? 0 : 1 }
            if affixChars.contains(c) || prefixOnly.contains(c) || isSymbol(c) { return 1 }
            return 0
        }

        /// spaCy runs `suffix_search` (a `$`-anchored alternation): the leftmost position whose
        /// remainder matches one of the suffix rules wins.
        private static func suffixLength(_ s: String) -> Int {
            let chars = Array(s)
            for p in 0..<chars.count {
                let rest = String(chars[p...])
                let prev: Character? = p > 0 ? chars[p - 1] : nil
                let prev2: Character? = p > 1 ? chars[p - 2] : nil
                if rest.count == 1, let c = rest.first, affixChars.contains(c) || isSymbol(c) || c == "—" || c == "–" { return 1 }
                if rest.count >= 2 && rest.allSatisfy({ $0 == "." }) { return rest.count }
                if ["'s", "'S", "’s", "’S"].contains(rest) { return 2 }
                if let prev, Text.isASCIIDigit(prev) {
                    if rest == "+" || currencySymbols.contains(rest) || units.contains(rest) { return rest.count }
                }
                if rest == "." {
                    if let prev2, prev2 == "°", let prev, "FfCcKk".contains(prev) { return 1 }
                    if let prev, Text.isASCIIDigit(prev) || prev.isLowercase || "%²-+…".contains(prev) || quoteChars.contains(prev) || punctChars.contains(prev) { return 1 }
                    if let prev, let prev2, prev.isUppercase, prev2.isUppercase { return 1 }
                }
            }
            return 0
        }

        private static func splitChunk(_ chunk: String, keepNumberAbbreviation: Bool) -> [Piece] {
            func isSpecial(_ s: String) -> Bool { specials.contains(s) || (keepNumberAbbreviation && s == "No.") }
            var prefixes: [String] = []
            var suffixes: [String] = []
            var str = chunk
            var lastCount = -1
            while !str.isEmpty && str.count != lastCount {
                if isSpecial(str) { break }
                lastCount = str.count
                let pre = prefixLength(str)
                if pre > 0 {
                    let minusPre = String(str.dropFirst(pre))
                    if !minusPre.isEmpty && isSpecial(minusPre) {
                        prefixes.append(String(str.prefix(pre)))
                        str = minusPre
                        break
                    }
                }
                let suf = suffixLength(String(str.dropFirst(pre)))
                if suf > 0 {
                    let minusSuf = String(str.dropLast(suf))
                    if !minusSuf.isEmpty && isSpecial(minusSuf) {
                        suffixes.append(String(str.suffix(suf)))
                        str = minusSuf
                        break
                    }
                }
                if pre > 0 && suf > 0 && pre + suf <= str.count {
                    prefixes.append(String(str.prefix(pre)))
                    suffixes.append(String(str.suffix(suf)))
                    str = String(str.dropFirst(pre).dropLast(suf))
                } else if pre > 0 {
                    prefixes.append(String(str.prefix(pre)))
                    str = String(str.dropFirst(pre))
                } else if suf > 0 {
                    suffixes.append(String(str.suffix(suf)))
                    str = String(str.dropLast(suf))
                }
                if isSpecial(str) { break }
            }
            var pieces = prefixes.map { Piece(text: $0, whitespace: "", side: .prefix) }
            if !str.isEmpty {
                pieces += isSpecial(str) ? [Piece(text: str, whitespace: "", side: .core)] : infixSplit(str)
            }
            pieces += suffixes.reversed().map { Piece(text: $0, whitespace: "", side: .suffix) }
            return pieces
        }

        /// spaCy's English infixes: dot runs, ellipsis, symbols, `-+*^` between digits, `.` between
        /// lower and upper case, `,` between letters, dashes and `:<>=/` before a letter.
        private static func infixMatch(_ c: [Character], _ i: Int) -> Int {
            let ch = c[i]
            let prev: Character? = i > 0 ? c[i - 1] : nil
            let next: Character? = i + 1 < c.count ? c[i + 1] : nil
            func letter(_ x: Character?) -> Bool { x?.isLetter == true }
            func digit(_ x: Character?) -> Bool { x.map(Text.isASCIIDigit) == true }
            if ch == "." && next == "." {
                var j = i
                while j < c.count && c[j] == "." { j += 1 }
                return j - i
            }
            if ch == "…" || isSymbol(ch) { return 1 }
            if "+-*^".contains(ch) && digit(prev) && (digit(next) || next == "-") { return 1 }
            if ch == ".", let prev, prev.isLowercase || quoteChars.contains(prev), next?.isUppercase == true { return 1 }
            if ch == ",", letter(prev), letter(next) { return 1 }
            if letter(prev) || digit(prev) {
                for dash in ["-", "–", "—", "--", "---", "——", "~"] {
                    let d = Array(dash)
                    guard i + d.count <= c.count, Array(c[i..<(i + d.count)]) == d else { continue }
                    if letter(i + d.count < c.count ? c[i + d.count] : nil) { return d.count }
                }
                if ":<>=/".contains(ch) && letter(next) { return 1 }
            }
            return 0
        }

        private static func infixSplit(_ s: String) -> [Piece] {
            let c = Array(s)
            var out: [Piece] = []
            var start = 0
            var i = 0
            while i < c.count {
                let n = infixMatch(c, i)
                guard n > 0 else { i += 1; continue }
                if i != start {
                    out.append(Piece(text: String(c[start..<i]), whitespace: "", side: .core))
                    out.append(Piece(text: String(c[i..<(i + n)]), whitespace: "", side: .core, before: c[i - 1], after: i + n < c.count ? c[i + n] : nil))
                    start = i + n
                }
                i += n
            }
            if start < c.count { out.append(Piece(text: String(c[start...]), whitespace: "", side: .core)) }
            return out
        }

        // MARK: Rule tagger

        static let determiners: Set<String> = ["the", "a", "an", "this", "these", "those", "some", "any", "no", "every",
                                               "each", "all", "both", "another", "either", "neither", "such"]
        static let pronouns: Set<String> = ["i", "you", "he", "she", "it", "we", "they", "me", "him", "us", "them"]
        static let possessives: Set<String> = ["my", "your", "his", "her", "its", "our", "their"]
        static let prepositions: Set<String> = [
            "in", "on", "at", "by", "for", "with", "from", "of", "about", "into", "over", "under", "after", "before",
            "between", "through", "during", "without", "within", "against", "among", "across", "behind", "near", "since",
            "until", "upon", "than", "as", "if", "because", "while", "although", "though", "whether", "like", "per", "via",
            "vs", "vs.", "versus", "around", "toward", "towards", "despite", "onto", "throughout", "beyond", "above", "below",
            "beside", "besides", "unlike", "amid", "along", "outside", "inside", "whereas", "unless", "once",
        ]
        static let modals: Set<String> = ["will", "would", "can", "could", "shall", "should", "may", "might", "must",
                                          "'ll", "'d", "wo", "ca", "cannot", "won't", "can't", "couldn't", "wouldn't",
                                          "shouldn't", "mustn't", "don't", "doesn't", "didn't", "to", "please", "let's"]
        static let haveForms: Set<String> = ["has", "have", "had", "having", "'ve", "'s"]
        static let beForms: Set<String> = ["is", "are", "was", "were", "be", "been", "being", "'re", "'m", "isn't",
                                           "aren't", "wasn't", "weren't", "get", "gets", "got", "getting", "become", "became"]
        static let numberWords: Set<String> = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight",
                                               "nine", "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen",
                                               "sixteen", "seventeen", "eighteen", "nineteen", "twenty", "thirty", "forty",
                                               "fifty", "sixty", "seventy", "eighty", "ninety", "hundred", "thousand",
                                               "million", "billion", "trillion", "dozen"]
        static let objectStarters: Set<String> = ["the", "a", "an", "this", "these", "those", "his", "her", "their", "its",
                                                  "our", "my", "your", "it", "them", "him", "me", "us", "some", "all",
                                                  "no", "every", "each", "any"]
        static let complementVerbs: Set<String> = [
            "said", "says", "say", "saying", "think", "thinks", "thought", "believe", "believes", "believed", "know", "knows",
            "knew", "known", "so", "such", "now", "ensure", "ensured", "show", "shows", "showed", "shown", "found", "find",
            "finds", "reported", "report", "announced", "noted", "argued", "claimed", "added", "told", "suggest", "suggests",
            "suggested", "means", "meant", "hope", "hoped", "feel", "felt", "realized", "realize", "clear", "sure", "fact",
            "warned", "stated", "explained", "insisted", "agreed", "decided", "admitted", "confirmed", "indicated", "predicted",
            "estimated", "expected", "assumed", "concluded", "revealed", "wrote", "writes", "learned", "discovered", "given",
        ]

        /// Splits `text` the way spaCy does and tags every token. `isWord` says whether the lexicon
        /// knows a (lowercase) word; `heteronyms` are the gold keys with per-tag readings.
        static func tokens(_ text: String, isWord: (String) -> Bool, heteronyms: Set<String>) -> [Token] {
            let pieces = split(text)
            var tokens: [Token] = []
            var doubleOpen = false
            var singleOpen = false
            for (i, piece) in pieces.enumerated() {
                let t = piece.text
                let lower = t.lowercased()
                let prevToken = tokens.last
                let sentenceStart = prevToken.map { [".", ":", "``"].contains($0.tag) } ?? true
                var tag = "NN"

                if t.contains(where: \.isNumber) {
                    tag = t.allSatisfy({ Text.isASCIIDigit($0) || ",.-".contains($0) }) || Lexicon.isNumber(t, isHead: true) ? "CD" : "NNP"
                } else if currencySymbols.contains(t) {
                    tag = "$"
                } else if !t.contains(where: { $0.isLetter }) {
                    switch t {
                    case ".", "!", "?": tag = "."
                    case ",": tag = ","
                    case ":", ";", "…", "—", "–", "--", "...": tag = ":"
                    case "-":
                        if piece.side == .alone { tag = ":" } else if piece.before.map(Text.isASCIIDigit) == true { tag = "SYM" } else { tag = "HYPH" }
                    case "(", "[", "{": tag = "-LRB-"
                    case ")", "]", "}": tag = "-RRB-"
                    case "\"":
                        let opens = quoteOpens(pieces, i, previous: prevToken, open: doubleOpen)
                        tag = opens ? "``" : "''"
                        doubleOpen = opens
                    case "“": tag = "``"; doubleOpen = true
                    case "”": tag = "''"; doubleOpen = false
                    case "'", "‘", "’":
                        let opens = t == "‘" || (t != "’" && quoteOpens(pieces, i, previous: prevToken, open: singleOpen))
                        if opens {
                            tag = "``"; singleOpen = true
                        } else if singleOpen {
                            tag = "''"; singleOpen = false
                        } else if let p = prevToken, p.whitespace.isEmpty, p.text.last.map({ "sS".contains($0) }) == true {
                            tag = "POS"
                        } else {
                            tag = "''"
                        }
                    case "&": tag = "CC"
                    case "%": tag = "NN"
                    case "/", "+", "=", "<", ">": tag = "SYM"
                    case "@": tag = "IN"
                    default: tag = t.allSatisfy({ $0 == "." }) ? "." : "NFP"
                    }
                } else if lower == "'s" || lower == "’s" {
                    tag = prevToken.map { pronouns.contains($0.text.lowercased()) || $0.text.lowercased() == "that" || $0.text.lowercased() == "there" } == true ? "VBZ" : "POS"
                } else if numberWords.contains(lower) {
                    tag = "CD"
                } else if t == "I" {
                    // "World War I", "the I Squadron": a numeral after a name or determiner.
                    tag = prevToken.map { ($0.tag == "NNP" || $0.tag == "DT") && $0.text.contains(where: \.isLetter) } == true ? "NNP" : "PRP"
                } else if t == "A" {
                    tag = i + 1 < pieces.count && pieces[i + 1].text.contains(where: { $0.isLetter || $0.isNumber }) ? "DT" : "NNP"
                } else if lower == "am" && t != "AM" {
                    tag = prevToken?.tag == "CD" ? "NN" : "VBP"
                } else if determiners.contains(lower) && closedClassCase(t) {
                    tag = "DT"
                } else if lower == "that" && closedClassCase(t) {
                    tag = thatTag(pieces, i, sentenceStart: sentenceStart)
                } else if lower == "to" && closedClassCase(t) {
                    tag = "TO"
                } else if pronouns.contains(lower) && closedClassCase(t) && t != "US" && t != "IT" {
                    tag = "PRP"
                } else if possessives.contains(lower) && closedClassCase(t) {
                    tag = "PRP$"
                } else if prepositions.contains(lower) && closedClassCase(t) {
                    tag = "IN"
                } else if lower == "used" {
                    tag = haveOrBeBefore(tokens) ? "VBN" : "VBD"
                } else if t.count > 1 && t == t.uppercased() {
                    tag = "NNP"
                } else if t != lower && (!sentenceStart || t.dropFirst().contains(where: \.isUppercase) || !isWord(lower)) {
                    tag = "NNP"
                } else if let (base, form) = heteronymForm(lower, heteronyms) {
                    tag = heteronymTag(pieces, i, tokens: tokens, base: base, form: form)
                }
                tokens.append(Token(text: t, tag: tag, whitespace: piece.whitespace))
            }
            return tokens
        }

        private static func nextWord(_ pieces: [Piece], _ i: Int) -> String? {
            guard i + 1 < pieces.count else { return nil }
            let t = pieces[i + 1].text
            return t.contains(where: \.isLetter) ? t.lowercased() : nil
        }

        /// Function words keep their tag in lower, Capitalized and ALL-CAPS writing.
        private static func closedClassCase(_ t: String) -> Bool {
            t == t.lowercased() || t == Text.capitalize(t) || t == t.uppercased()
        }

        private static let adverbs: Set<String> = ["also", "not", "never", "still", "often", "already", "then", "now",
                                                   "just", "even", "only", "first", "later", "since", "n't", "always"]

        /// The nearest word before the current token, skipping adverbs, is a form of have/be.
        private static func haveOrBeBefore(_ tokens: [Token]) -> Bool {
            for tk in tokens.reversed() {
                let w = tk.text.lowercased()
                if adverbs.contains(w) || (w.hasSuffix("ly") && w.count > 3) { continue }
                return beForms.contains(w) || haveForms.contains(w)
            }
            return false
        }

        /// Opening or closing quote: attached to the word after it opens, attached to the word before
        /// it closes, standing alone it flips the open/closed state.
        private static func quoteOpens(_ pieces: [Piece], _ i: Int, previous: Token?, open: Bool) -> Bool {
            let prevAttached = previous.map { $0.whitespace.isEmpty && !["``", "-LRB-", "$"].contains($0.tag) } ?? false
            let nextAttached = pieces[i].whitespace.isEmpty && i + 1 < pieces.count
                && pieces[i + 1].text.contains(where: { $0.isLetter || $0.isNumber || "([{$£€".contains($0) })
            if prevAttached != nextAttached { return nextAttached }
            return !open
        }

        /// "that": DT (stressed ðˈæt) when it is a pronoun or points at a noun ("that year"),
        /// IN/WDT (ðæt) when it joins clauses — spaCy's choice in ~90% of article text.
        private static func thatTag(_ pieces: [Piece], _ i: Int, sentenceStart: Bool) -> String {
            guard let next = nextWord(pieces, i) else {
                let after = i + 1 < pieces.count ? pieces[i + 1].text : "."
                return [".", "!", "?", ";"].contains(after) ? "DT" : "IN"
            }
            if sentenceStart { return "DT" }
            let prev = i > 0 ? pieces[i - 1].text.lowercased() : ""
            if next == "'s" { return [",", ";", ":", "and", "but", "or", "so"].contains(prev) ? "DT" : "IN" }
            let function = pronouns.contains(next) || determiners.contains(next) || possessives.contains(next)
                || prepositions.contains(next) || modals.contains(next) || beForms.contains(next) || haveForms.contains(next)
                || ["there", "and", "or", "but", "not", "most", "many", "much", "more", "if", "when"].contains(next)
            if !function && (prepositions.contains(prev) || ["later", "earlier", "all", "after", "before"].contains(prev)) { return "DT" }
            return "IN"
        }

        enum Form { case base, s, ed, ing }

        /// A heteronym or an inflection of one ("records", "lived", "recording"), with its base.
        private static func heteronymForm(_ w: String, _ heteronyms: Set<String>) -> (String, Form)? {
            func has(_ x: Substring) -> Bool { heteronyms.contains(String(x)) }
            if w.hasSuffix("ies"), has(w.dropLast(3) + "y") { return (String(w.dropLast(3)) + "y", .s) }
            if w.hasSuffix("es"), has(w.dropLast(2)) { return (String(w.dropLast(2)), .s) }
            if w.hasSuffix("s"), has(w.dropLast()) { return (String(w.dropLast()), .s) }
            if heteronyms.contains(w) { return (w, .base) }
            if w.hasSuffix("ed") {
                if has(w.dropLast(2)) { return (String(w.dropLast(2)), .ed) }
                if has(w.dropLast()) { return (String(w.dropLast()), .ed) }
            }
            if w.hasSuffix("ing") {
                let stem = w.dropLast(3)
                if has(stem) { return (String(stem), .ing) }
                if has(stem + "e") { return (String(stem) + "e", .ing) }
                if stem.count > 2, stem.last == stem.dropLast().last, has(stem.dropLast()) { return (String(stem.dropLast()), .ing) }
            }
            return nil
        }

        private static func isNounTag(_ tag: String?) -> Bool { tag.map { $0.hasPrefix("NN") } == true }

        /// Heteronyms: a verb after a modal/"to"/a subject or before an object, a noun after a
        /// determiner, a participle after have/be; inflections pick VBZ/NNS, VBD/VBN, VBG.
        private static func heteronymTag(_ pieces: [Piece], _ i: Int, tokens: [Token], base: String, form: Form) -> String {
            let previous = tokens.last
            let prev = previous?.text.lowercased() ?? ""
            let next = nextWord(pieces, i)
            let nounBefore = previous.map { isNounTag($0.tag) && $0.text.contains(where: \.isLetter) } == true
            switch form {
            case .ing:
                return "VBG"
            case .ed:
                return haveOrBeBefore(tokens) ? "VBN" : "VBD"
            case .s:
                if determiners.contains(prev) || possessives.contains(prev) || prepositions.contains(prev) { return "NNS" }
                // A word right after a modal/subject is the verb, so this one is its object.
                if tokens.count >= 2, (modals.union(["i", "we", "you", "they", "he", "she", "it"])).contains(tokens[tokens.count - 2].text.lowercased()) { return "NNS" }
                if ["he", "she", "it", "which", "who", "that"].contains(prev) || previous?.tag == "NNP" { return "VBZ" }
                if let next, objectStarters.contains(next) || numberWords.contains(next) || (prepositions.contains(next) && !["of", "for", "as", "than"].contains(next)) { return "VBZ" }
                if i + 1 < pieces.count, pieces[i + 1].text.first.map(Text.isASCIIDigit) == true { return "VBZ" }
                return "NNS"
            case .base:
                if modals.contains(prev) || prev == "n't" || prev == "not" || prev.hasSuffix("'ll") || prev.hasSuffix("'d") || prev.hasSuffix("n't") { return "VB" }
                if ["i", "we", "you", "they"].contains(prev) { return "VBP" }
                if ["he", "she", "it"].contains(prev) { return "VBD" }
                if haveForms.contains(prev) { return "VBN" }
                if beForms.contains(prev) { return ["read", "reread", "wound"].contains(base) ? "VBN" : "JJ" }
                if determiners.contains(prev) || possessives.contains(prev) || prepositions.contains(prev) { return "NN" }
                if nounBefore && ["read", "reread", "wound"].contains(base) { return "VBD" }
                if let next, objectStarters.contains(next) { return "VB" }
                if next == "to" || next == "by" { return "RB" }
                if next == nil && ["overall", "underground", "uphill"].contains(base) { return "RB" }
                return "NN"
            }
        }
    }
}
