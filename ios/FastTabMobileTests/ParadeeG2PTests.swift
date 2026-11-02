import XCTest
@testable import FastTabMobile

/// Paradee's on-device text → phonemes (`ParadeeG2P`, a Swift port of misaki) against misaki itself.
/// `ParadeeG2PGolden.json`: 313 article-style sentences (news, tech, numbers, dates, money, names,
/// quotes, abbreviations) run through Python misaki 0.9.4 exactly as Kokoro/Paradee run it, both accents.
/// Words misaki could only read with espeak-ng (GPL, not shippable) are listed per row; we can't
/// match those, so the strict thresholds apply to the rows without them.
final class ParadeeG2PTests: XCTestCase {
    private struct Golden: Decodable {
        struct Row: Decodable {
            let text: String
            let us: String
            let gb: String
            let us_fallback: [String]?
            let gb_fallback: [String]?
        }
        let sentences: [Row]
    }

    private static let g2p = ParadeeG2P()

    private func golden() throws -> [Golden.Row] {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "ParadeeG2PGolden", withExtension: "json"),
                                "ParadeeG2PGolden.json missing from the test bundle")
        return try JSONDecoder().decode(Golden.self, from: Data(contentsOf: url)).sentences
    }

    private func lcs(_ a: [Substring], _ b: [Substring]) -> Int {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var prev = [Int](repeating: 0, count: b.count + 1)
        for x in a {
            var cur = [Int](repeating: 0, count: b.count + 1)
            for (j, y) in b.enumerated() { cur[j + 1] = x == y ? prev[j] + 1 : max(prev[j + 1], cur[j]) }
            prev = cur
        }
        return prev[b.count]
    }

    // MARK: - Match rates

    private func assertMatchRates(_ accent: ParadeeAccent, file: StaticString = #filePath, line: UInt = #line) throws {
        let rows = try golden()
        XCTAssertGreaterThanOrEqual(rows.count, 300)
        var exact = 0, clean = 0, cleanExact = 0, words = 0, wordHits = 0
        var misses: [String] = []
        for row in rows {
            let expected = accent == .american ? row.us : row.gb
            let fallback = accent == .american ? row.us_fallback : row.gb_fallback
            let got = Self.g2p.phonemes(for: row.text, accent: accent)
            let ref = expected.split(separator: " "), hyp = got.split(separator: " ")
            words += ref.count
            wordHits += lcs(ref, hyp)
            if fallback == nil { clean += 1 }
            if got == expected {
                exact += 1
                if fallback == nil { cleanExact += 1 }
            } else if fallback == nil {
                misses.append("\(row.text)\n  misaki \(expected)\n  swift  \(got)")
            }
        }
        let sentenceRate = Double(exact) / Double(rows.count)
        let cleanRate = Double(cleanExact) / Double(max(clean, 1))
        let wordRate = Double(wordHits) / Double(words)
        // Measured on macOS at commit time: 94.2% / 100% / 99.3% (both accents).
        XCTAssertGreaterThanOrEqual(sentenceRate, 0.88, "sentence exact match", file: file, line: line)
        XCTAssertGreaterThanOrEqual(cleanRate, 0.97, "sentence exact match, rows without espeak words:\n" + misses.prefix(5).joined(separator: "\n"), file: file, line: line)
        XCTAssertGreaterThanOrEqual(wordRate, 0.97, "per-word match", file: file, line: line)
    }

    func testAmericanMatchesMisaki() throws { try assertMatchRates(.american) }

    func testBritishMatchesMisaki() throws { try assertMatchRates(.british) }

    // MARK: - Must-pass sentences

    /// Rows that exercise each rule; these must match misaki character for character.
    func testMustPassSentencesMatchExactly() throws {
        let mustPass = [
            "The company reported revenue of $4.2 billion, up 12% from a year earlier.",           // currency + scale word, percent
            "Dr. Smith and Mr. Jones met with the mayor at 10 a.m. on Monday.",                     // abbreviations
            "The U.S. economy added 250,000 jobs in March, according to the Labor Department.",    // dotted initials, grouped digits
            "I read the book last week, and I'll read it again next year.",                         // heteronym by context
            "\"We're not going to give up,\" she said after the meeting.",                          // curly quotes, contractions
            "'It's too late,' she whispered.",                                                       // single quotes
            "The well-known author signed copies of her latest book.",                              // hyphenated compound stress
            "The 1990s were a period of rapid change in the tech industry.",                        // decade
            "Her grandmother was born in 1905 in a small village in Italy.",                        // year "oh-five"
            "He finished in 21st place.",                                                            // ordinal
            "The temperature dropped to -5 degrees overnight.",                                     // negative number
            "The Lakers beat the Celtics 112-108 in overtime.",                                     // score
            "He works at a hospital (the one near the park) as a nurse.",                           // parentheses
            "Some critics — including several former officials — called the decision a mistake.",   // em dash
            "The new MacBook Pro has an M3 chip and up to 128GB of memory.",                        // units, letters + digits
            "The app is available for iOS and Android devices.",                                     // camelCase brand
            "The stock trades under the ticker symbol AAPL.",                                        // spelled acronym
            "The trade deficit narrowed to $65 billion.",                                            // currency before a scale word
            "The colour of the leaves changes in autumn.",                                          // British spelling
            "Net income was $3.1 billion, or $1.25 a share.",                                       // dollars and cents
        ]
        let rows = Dictionary(uniqueKeysWithValues: try golden().map { ($0.text, $0) })
        for text in mustPass {
            let row = try XCTUnwrap(rows[text], "must-pass sentence missing from the fixture: \(text)")
            XCTAssertEqual(Self.g2p.phonemes(for: text, accent: .american), row.us, text)
            XCTAssertEqual(Self.g2p.phonemes(for: text, accent: .british), row.gb, text)
        }
    }

    func testLibrarySentenceMatchesMisakiBothAccents() {
        let text = "The library opens at nine, but the coffee shop next door is usually busy by eight."
        XCTAssertEqual(Self.g2p.phonemes(for: text, accent: .american),
                       "ðə lˈIbɹˌɛɹi ˈOpᵊnz æt nˈIn, bˌʌt ðə kˈɔfi ʃˈɑp nˈɛkst dˈɔɹ ɪz jˈuʒəwəli bˈɪzi bI ˈAt.")
        XCTAssertEqual(Self.g2p.phonemes(for: text, accent: .british),
                       "ðə lˈIbɹəɹi ˈQpᵊnz at nˈIn, bˌʌt ðə kˈɒfi ʃˈɒp nˈɛkst dˈɔː ɪz jˈuːʒʊəli bˈɪzi bI ˈAt.")
    }

    // MARK: - Pieces

    func testNumberWordsMatchNum2words() {
        typealias N = ParadeeG2P.NumberWords
        XCTAssertEqual(N.cardinal(1_200), "one thousand, two hundred")
        XCTAssertEqual(N.cardinal(105), "one hundred and five")
        XCTAssertEqual(N.cardinal(2_000_050), "two million and fifty")
        XCTAssertEqual(N.ordinal(21), "twenty-first")
        XCTAssertEqual(N.ordinal(40), "fortieth")
        XCTAssertEqual(N.year(1905), "nineteen oh-five")
        XCTAssertEqual(N.year(2000), "two thousand")
        XCTAssertEqual(N.year(2015), "twenty fifteen")
        XCTAssertEqual(N.decimal("3.14"), "three point one four")
        XCTAssertEqual(N.decimal("2.0"), "two")
    }

    /// Words no dictionary has still get a pronunciation: one primary stress, only phonemes Paradee knows.
    func testUnknownWordsGetRulesBasedPhonemes() {
        let vocab = Set("AIOQWYabdfhijklmnpstuvwzæðŋɑɒɔəɛɜɡɪɹɾʃʊʌʒʤʧˈˌːθᵊᵻT")
        for accent in [ParadeeAccent.american, .british] {
            for word in ["Zorblaxian", "Kosygin", "Brauchitsch", "McClellin", "snorfleworthy"] {
                let ps = Self.g2p.phonemes(for: word, accent: accent)
                XCTAssertFalse(ps.isEmpty, word)
                XCTAssertEqual(ps.filter { $0 == "ˈ" }.count, 1, "\(word) → \(ps)")
                XCTAssertTrue(ps.allSatisfy(vocab.contains), "\(word) → \(ps)")
            }
        }
    }

    /// Everything the G2P emits is in Paradee's token vocabulary (anything else would be dropped silently).
    func testOutputOnlyUsesModelVocabulary() throws {
        let allowed = Set("AIOQWYTabdfhijklmnpstuvwzæðŋɑɒɔəɛɜɡɪɹʃʊʌʒʤʧˈˌːθᵊᵻɐ ;:,.!?—…\"“”()")
        for row in try golden() {
            for accent in [ParadeeAccent.american, .british] {
                let ps = Self.g2p.phonemes(for: row.text, accent: accent)
                let stray = ps.filter { !allowed.contains($0) }
                XCTAssertTrue(stray.isEmpty, "\(row.text) → unexpected \(stray)")
            }
        }
    }

    func testOddInputNeverCrashesOrLeaksUnknownMarks() {
        for text in ["", "   ", "…", "🎉🎉", "$", "1e10", "99999999999999999999999", "http://example.com/a?b=1", "C++ & C#", "日本語"] {
            for accent in [ParadeeAccent.american, .british] {
                XCTAssertFalse(Self.g2p.phonemes(for: text, accent: accent).contains("❓"), text)
            }
        }
    }
}
