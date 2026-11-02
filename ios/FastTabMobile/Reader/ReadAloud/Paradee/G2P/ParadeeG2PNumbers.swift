import Foundation

extension ParadeeG2P {
    /// The English spellings misaki gets from `num2words` (cardinal, ordinal, year, decimal),
    /// word for word: "one hundred and five", "twenty-first", "nineteen oh-five", "three point one four".
    /// misaki then splits on non-letters and drops "and", so only the word sequence matters.
    enum NumberWords {
        private static let low = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
                                  "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen"]
        private static let tens = ["", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"]
        /// Short scale, as num2words' English converter.
        private static let scales: [(Int, String)] = [
            (1_000_000_000_000_000_000, "quintillion"), (1_000_000_000_000_000, "quadrillion"),
            (1_000_000_000_000, "trillion"), (1_000_000_000, "billion"), (1_000_000, "million"), (1000, "thousand"),
        ]
        private static let ords = ["one": "first", "two": "second", "three": "third", "four": "fourth", "five": "fifth",
                                   "six": "sixth", "seven": "seventh", "eight": "eighth", "nine": "ninth", "ten": "tenth",
                                   "eleven": "eleventh", "twelve": "twelfth"]

        /// Below 1000: "one hundred and twenty-three".
        private static func underThousand(_ n: Int) -> String {
            if n < 20 { return low[n] }
            if n < 100 { return tens[n / 10] + (n % 10 == 0 ? "" : "-" + low[n % 10]) }
            let rest = n % 100
            return low[n / 100] + " hundred" + (rest == 0 ? "" : " and " + underThousand(rest))
        }

        static func cardinal(_ value: Int) -> String {
            if value < 0 { return "minus " + cardinal(-value) }
            if value < 1000 { return underThousand(value) }
            var parts: [String] = []
            var n = value
            for (size, name) in scales where n >= size {
                parts.append(cardinal(n / size) + " " + name)
                n %= size
            }
            if n > 0 {
                // num2words joins a trailing part below 100 with "and", otherwise with ", ".
                if n < 100 { return parts.joined(separator: ", ") + " and " + underThousand(n) }
                parts.append(underThousand(n))
            }
            return parts.joined(separator: ", ")
        }

        static func ordinal(_ value: Int) -> String {
            var words = cardinal(value).components(separatedBy: " ")
            var last = words[words.count - 1].components(separatedBy: "-")
            let word = last[last.count - 1]
            if let ord = ords[word] {
                last[last.count - 1] = ord
            } else if word.hasSuffix("y") {
                last[last.count - 1] = String(word.dropLast()) + "ieth"
            } else {
                last[last.count - 1] = word + "th"
            }
            words[words.count - 1] = last.joined(separator: "-")
            return words.joined(separator: " ")
        }

        /// num2words `to_year`: 1905 → "nineteen oh-five", 2000 → "two thousand", 2015 → "twenty fifteen".
        static func year(_ value: Int) -> String {
            let v = abs(value)
            let high = v / 100, low = v % 100
            let text: String
            if high == 0 || (high % 10 == 0 && low < 10) || high >= 100 {
                text = cardinal(v)
            } else {
                let lowText = low == 0 ? "hundred" : (low < 10 ? "oh-" + cardinal(low) : cardinal(low))
                text = cardinal(high) + " " + lowText
            }
            return value < 0 ? text + " BC" : text
        }

        /// num2words of a float: a whole value reads as a cardinal, otherwise the integer part, "point",
        /// then each decimal digit of the shortest repr (Swift and Python print the same shortest form).
        static func decimal(_ text: String) -> String {
            guard let value = Double(text), value.isFinite, abs(value) < 1e15 else { return text }
            if value == value.rounded(.towardZero) { return cardinal(Int(value)) }
            var repr = "\(abs(value))"
            if repr.contains("e") {
                repr = String(format: "%.12f", abs(value))
                while repr.hasSuffix("0") { repr.removeLast() }
            }
            let pieces = repr.split(separator: ".", omittingEmptySubsequences: false)
            let whole = Int(value.rounded(.towardZero))
            var out = [cardinal(whole), "point"]
            if pieces.count > 1 { out.append(contentsOf: pieces[1].map { low[Int(String($0)) ?? 0] }) }
            return out.joined(separator: " ")
        }
    }
}
