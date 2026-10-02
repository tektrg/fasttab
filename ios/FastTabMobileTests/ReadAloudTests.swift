import XCTest
@testable import FastTabMobile

/// Read Aloud: plain-text extraction/chunking, voice selection, settings back-compat.
final class ReadAloudTests: XCTestCase {

    // MARK: - Text extraction

    func testParagraphsSplitOnBlocksStripTagsAndDecodeEntities() {
        let html = """
        <h2>Intro</h2><p>Hello <a href="x">world</a> &amp; friends&#8217;s&nbsp;day.</p>
        <ul><li>One</li><li>Two</li></ul><p>Line<br>break</p>
        """
        XCTAssertEqual(
            ReadAloudText.paragraphs(fromHTML: html),
            ["Intro", "Hello world & friends’s day.", "One", "Two", "Line", "break"]
        )
    }

    func testCodeScriptsAndCommentsAreNotSpoken() {
        let html = "<p>Keep</p><pre>let x = 1</pre><script>alert(1)</script><!-- c --><p>Too</p>"
        XCTAssertEqual(ReadAloudText.paragraphs(fromHTML: html), ["Keep", "Too"])
    }

    func testUnknownEntityIsLeftAsIs() {
        XCTAssertEqual(ReadAloudText.decodeEntities("a &bogus; b &#x41;"), "a &bogus; b A")
    }

    func testChunksStartWithTitleAndSkipEmptyBlocks() {
        let article = ReaderArticle(title: "  My Title ", content: "<p> </p><p>Body</p>", url: URL(string: "https://e.com")!)
        XCTAssertEqual(ReadAloudText.chunks(for: article), ["My Title", "Body"])
    }

    func testLongParagraphIsSplitAtSentencesUnderLimit() {
        // Capitalised sentence starts, so the sentence tokenizer sees real boundaries.
        let sentence = "Word " + String(repeating: "word ", count: 59) + "end. " // ~305 chars
        let paragraph = String(repeating: sentence, count: 10).trimmingCharacters(in: .whitespaces)
        let chunks = ReadAloudText.splitLongParagraph(paragraph)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= ReadAloudText.maxChunkLength })
        XCTAssertTrue(chunks.allSatisfy { $0.hasSuffix("end.") })
    }

    func testRunOnTextWithoutSentenceBoundariesIsSplitAtSpaces() {
        // Lower-case after each period: the tokenizer finds no boundary (transcripts look like this).
        let paragraph = String(repeating: "word word word end. ", count: 200).trimmingCharacters(in: .whitespaces)
        let chunks = ReadAloudText.splitLongParagraph(paragraph)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= ReadAloudText.maxChunkLength })
        XCTAssertEqual(chunks.joined(separator: " "), paragraph) // nothing lost, no word cut
    }

    func testSplitChunksStillMapOntoPageText() {
        let paragraph = String(repeating: "alpha beta gamma. ", count: 150).trimmingCharacters(in: .whitespaces)
        let chunks = ["Title"] + ReadAloudText.splitLongParagraph(paragraph)
        let page = "Title" + paragraph // as ftReadAloudText joins title + body
        let locator = ReadAloudTextLocator(documentText: page, chunks: chunks)
        XCTAssertFalse(locator.chunkStarts.contains { $0 == nil })
        let pageText = page as NSString
        for (index, chunk) in chunks.enumerated() {
            let ranges = locator.documentRanges(
                for: ReadAloudSpokenPosition(sessionID: 1, chunkIndex: index, wordRange: NSRange(location: 0, length: 5)))
            XCTAssertEqual(ranges.map { pageText.substring(with: $0.paragraph) }, chunk)
            XCTAssertEqual(ranges.map { pageText.substring(with: $0.word) }, String(chunk.prefix(5)))
        }
    }

    func testDominantLanguageDetectsEnglish() {
        let chunks = ["The quick brown fox jumps over the lazy dog while the sun sets over the quiet hills."]
        XCTAssertEqual(ReadAloudText.dominantLanguage(of: chunks), "en")
    }

    // MARK: - Voice selection

    private let voices = [
        ReadAloudVoiceOption(id: "en-us-std", name: "Fred", languageCode: "en-US", quality: .standard),
        ReadAloudVoiceOption(id: "en-gb-enh", name: "Daniel", languageCode: "en-GB", quality: .enhanced),
        ReadAloudVoiceOption(id: "en-us-enh", name: "Ava", languageCode: "en-US", quality: .enhanced),
        ReadAloudVoiceOption(id: "vi-std", name: "Linh", languageCode: "vi-VN", quality: .standard),
        ReadAloudVoiceOption(id: "en-au-prem", name: "Karen", languageCode: "en-AU", quality: .premium),
    ]

    func testAutomaticPrefersHighestQualityForLanguage() {
        let picked = ReadAloudVoiceSelector.select(preferredIdentifier: nil, languageCode: "en", among: voices, preferredRegion: "US")
        XCTAssertEqual(picked?.id, "en-au-prem")
    }

    func testSameQualityPrefersDeviceRegion() {
        let ranked = ReadAloudVoiceSelector.voices(for: "en", among: voices, preferredRegion: "US").map(\.id)
        XCTAssertEqual(ranked, ["en-au-prem", "en-us-enh", "en-gb-enh", "en-us-std"])
    }

    func testSavedVoiceUsedOnlyWhenLanguageMatches() {
        XCTAssertEqual(
            ReadAloudVoiceSelector.select(preferredIdentifier: "en-us-std", languageCode: "en", among: voices)?.id,
            "en-us-std"
        )
        XCTAssertEqual(
            ReadAloudVoiceSelector.select(preferredIdentifier: "en-us-std", languageCode: "vi", among: voices)?.id,
            "vi-std"
        )
    }

    func testNoVoiceForLanguageReturnsNil() {
        XCTAssertNil(ReadAloudVoiceSelector.select(preferredIdentifier: nil, languageCode: "ja", among: voices))
    }

    // MARK: - Chunk ↔ page text mapping

    private func position(_ chunk: Int, _ location: Int, _ length: Int) -> ReadAloudSpokenPosition {
        ReadAloudSpokenPosition(sessionID: 1, chunkIndex: chunk, wordRange: NSRange(location: location, length: length))
    }

    func testChunksMapInReadingOrderIncludingRepeats() {
        // Page text as `ftReadAloudText` builds it: title + body, whitespace collapsed, no separators.
        let page = "Title Hello world.Hello world.Line break"
        let chunks = ["Title", "Hello world.", "Hello world.", "Line", "break"]
        let locator = ReadAloudTextLocator(documentText: page, chunks: chunks)
        XCTAssertEqual(locator.chunkStarts, [0, 6, 18, 30, 35])
    }

    func testWordRangeIsOffsetByChunkStart() {
        let locator = ReadAloudTextLocator(documentText: "My Title Hello brave world.", chunks: ["My Title", "Hello brave world."])
        XCTAssertEqual(
            locator.documentRanges(for: position(1, 6, 5)),
            ReadAloudDocumentRanges(paragraph: NSRange(location: 9, length: 18), word: NSRange(location: 15, length: 5))
        )
    }

    func testOffsetsAreUTF16LikeJavaScript() {
        let locator = ReadAloudTextLocator(documentText: "😀 emoji then text", chunks: ["then text"])
        XCTAssertEqual(locator.chunkStarts, [9]) // the emoji is 2 UTF-16 units
    }

    func testMissingChunkHasNoRangeAndDoesNotBreakLaterChunks() {
        let locator = ReadAloudTextLocator(documentText: "Alpha Gamma", chunks: ["Alpha", "Beta (re-cleaned)", "Gamma"])
        XCTAssertEqual(locator.chunkStarts, [0, nil, 6])
        XCTAssertNil(locator.documentRanges(for: position(1, 0, 4)))
        XCTAssertNil(locator.documentRanges(for: position(9, 0, 1)))
    }

    func testTappedOffsetMapsToTheChunkContainingIt() {
        // Page text as ftReadAloudText builds it; "let x = 1" is a code block no chunk speaks.
        let page = "Title First para.let x = 1Second para."
        let locator = ReadAloudTextLocator(documentText: page, chunks: ["Title", "First para.", "Second para."])
        XCTAssertEqual(locator.chunkIndex(containing: 0), 0)
        XCTAssertEqual(locator.chunkIndex(containing: 6), 1)   // "F"
        XCTAssertEqual(locator.chunkIndex(containing: 16), 1)  // final "."
        XCTAssertNil(locator.chunkIndex(containing: 5))        // space between title and body
        XCTAssertNil(locator.chunkIndex(containing: 20))       // inside the code block
        XCTAssertEqual(locator.chunkIndex(containing: 27), 2)
        XCTAssertNil(locator.chunkIndex(containing: 999))
    }

    func testWordRangeIsClampedToChunk() {
        let locator = ReadAloudTextLocator(documentText: "Short", chunks: ["Short"])
        XCTAssertEqual(locator.documentRanges(for: position(0, 3, 50))?.word, NSRange(location: 3, length: 2))
    }

    // MARK: - Settings

    func testSettingsSavedBeforeReadAloudStillDecode() throws {
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ReaderReadingSettings.defaults)) as! [String: Any]
        legacy.removeValue(forKey: "speechRate")
        legacy.removeValue(forKey: "speechVoiceIdentifier")
        let decoded = try JSONDecoder().decode(ReaderReadingSettings.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertEqual(decoded.effectiveSpeechRate, ReaderReadingSettings.defaultSpeechRate)
        XCTAssertNil(decoded.speechVoiceIdentifier)
    }
}
