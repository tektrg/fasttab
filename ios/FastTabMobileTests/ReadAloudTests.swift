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
        let sentence = String(repeating: "word ", count: 60) + "end. " // ~305 chars
        let paragraph = String(repeating: sentence, count: 10)
        let chunks = ReadAloudText.splitLongParagraph(paragraph)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= ReadAloudText.maxChunkLength })
        XCTAssertTrue(chunks.allSatisfy { $0.hasSuffix("end.") })
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
