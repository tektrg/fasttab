import XCTest
@testable import FastTabMobile

/// Find in Article: matching, wrap-around, the page bridge and the ••• menu.
final class ReaderFindTests: XCTestCase {

    private func substrings(_ text: String, _ query: String) -> [String] {
        let ns = text as NSString
        return ReaderFindMatcher(text: text).matches(for: query).map { ns.substring(with: $0) }
    }

    // MARK: Matcher

    func testCaseInsensitive() {
        XCTAssertEqual(substrings("The cat. THE end. the", "the"), ["The", "THE", "the"])
    }

    func testDiacriticInsensitiveVietnamese() {
        XCTAssertEqual(substrings("Tiếng Việt rất hay", "viet"), ["Việt"])
        XCTAssertEqual(substrings("Con Đường xa, đường gần", "duong"), ["Đường", "đường"])
        XCTAssertEqual(substrings("café", "CAFE"), ["café"])
        // Typing the accent still finds the plain word and vice versa.
        XCTAssertEqual(substrings("Viet Nam", "Việt"), ["Viet"])
    }

    func testRangesAreUTF16OffsetsInTheOriginalText() {
        // Emoji are 2 UTF-16 units; the range after it must still land on the word.
        let text = "😀 Đà Nẵng"
        let ranges = ReaderFindMatcher(text: text).matches(for: "da nang")
        XCTAssertEqual(ranges, [NSRange(location: 3, length: 7)])
        XCTAssertEqual((text as NSString).substring(with: ranges[0]), "Đà Nẵng")
    }

    func testMatchesNeverOverlap() {
        XCTAssertEqual(ReaderFindMatcher(text: "aaa").matches(for: "aa"), [NSRange(location: 0, length: 2)])
        XCTAssertEqual(ReaderFindMatcher(text: "aaaa").matches(for: "aa"),
                       [NSRange(location: 0, length: 2), NSRange(location: 2, length: 2)])
    }

    func testEmptyOrBlankQueryFindsNothing() {
        XCTAssertEqual(ReaderFindMatcher(text: "anything").matches(for: ""), [])
        XCTAssertEqual(ReaderFindMatcher(text: "a b").matches(for: "   "), [])
        XCTAssertEqual(ReaderFindMatcher(text: "").matches(for: "a"), [])
        XCTAssertEqual(ReaderFindMatcher(text: "ab").matches(for: "abc"), [])
    }

    func testQueryWhitespaceIsTrimmedAndCollapsed() {
        XCTAssertEqual(substrings("read the article", "  the   article "), ["the article"])
    }

    // MARK: Wrap-around

    func testNextAndPreviousWrapBothWays() {
        var state = ReaderFindState(query: "x")
        state.setResults(count: 3)
        XCTAssertEqual(state.current, 0)
        XCTAssertEqual(state.countLabel, "1 of 3")
        state.previous()
        XCTAssertEqual(state.current, 2)
        XCTAssertEqual(state.countLabel, "3 of 3")
        state.next()
        XCTAssertEqual(state.current, 0)
        state.next(); state.next(); state.next()
        XCTAssertEqual(state.current, 0)
    }

    func testNoMatchesAndEmptyQueryLabels() {
        var state = ReaderFindState(query: "zzz")
        state.setResults(count: 0)
        XCTAssertNil(state.current)
        state.next(); state.previous()
        XCTAssertNil(state.current)
        XCTAssertEqual(state.countLabel, "No matches")
        state.query = " "
        XCTAssertEqual(state.countLabel, "")
    }

    // MARK: Page bridge (sentinel-only hostile input)

    func testHostileQueryNeverReachesTheGeneratedJS() {
        let payloads = ["$(echo INJECTED)", "</script><b>INJECTED", "'); INJECTED('"]
        for payload in payloads {
            let text = "before \(payload) after \(payload)"
            let ranges = ReaderFindMatcher(text: text).matches(for: payload)
            XCTAssertEqual(ranges.count, 2, payload)
            for js in [ReaderFindJS.show(ranges: ranges, current: 1), ReaderFindJS.show(ranges: [], current: nil),
                       ReaderFindJS.clear, ReaderFindJS.fetchText] {
                XCTAssertFalse(js.contains("INJECTED"), js)
                XCTAssertFalse(js.contains("</script"), js)
                XCTAssertFalse(js.contains("$("), js)
            }
        }
    }

    func testShowJSIsAJSONPayloadOfNumbers() {
        let js = ReaderFindJS.show(ranges: [NSRange(location: 3, length: 7)], current: 0)
        XCTAssertEqual(js, "window.ftFindShow ? ftFindShow({\"ranges\":[[3,7]],\"current\":0}) : 'missing';")
    }

    // MARK: ••• menu

    func testMenuOrderWithAISection() {
        let entries = ReaderMoreMenu.entries(isLoaded: true, isEntitled: true, hasSavedSummary: false,
                                             cleanupAvailable: true)
        XCTAssertEqual(entries, [
            .item(.readingSettings), .item(.readAloudSettings),
            .section("AI", [.summary(showsPlus: false), .cleanUpTranscript]),
            .divider,
            .item(.findInArticle), .item(.reload), .item(.shareLink), .item(.openInSafari),
            .divider,
            .item(.saveToBookmarkFolder), .item(.deleteLink),
        ])
    }

    func testSummaryShowsPlusOnlyWhenLockedAndNothingSaved() {
        func summary(entitled: Bool, saved: Bool) -> ReaderMoreMenuEntry? {
            ReaderMoreMenu.entries(isLoaded: true, isEntitled: entitled, hasSavedSummary: saved,
                                   cleanupAvailable: false).first { if case .section = $0 { true } else { false } }
        }
        XCTAssertEqual(summary(entitled: false, saved: false), .section("AI", [.summary(showsPlus: true)]))
        XCTAssertEqual(summary(entitled: false, saved: true), .section("AI", [.summary(showsPlus: false)]))
        XCTAssertEqual(summary(entitled: true, saved: false), .section("AI", [.summary(showsPlus: false)]))
    }

    func testNotLoadedHidesSummaryAndFind() {
        let entries = ReaderMoreMenu.entries(isLoaded: false, isEntitled: true, hasSavedSummary: false,
                                             cleanupAvailable: false)
        XCTAssertEqual(entries, [
            .item(.readingSettings), .item(.readAloudSettings), .divider,
            .item(.reload), .item(.shareLink), .item(.openInSafari), .divider,
            .item(.saveToBookmarkFolder), .item(.deleteLink),
        ])
    }
}
