import XCTest
@testable import FastTabMobile

final class ClipboardLinkExtractorTests: XCTestCase {
    func testSingleBareURL() {
        XCTAssertEqual(ClipboardLinkExtractor.links(in: "https://example.com/a").map(\.absoluteString),
                       ["https://example.com/a"])
    }

    func testSeveralURLsInText() {
        let text = "read https://example.com/a and http://example.org/b, also https://example.net/c."
        XCTAssertEqual(ClipboardLinkExtractor.links(in: text).map(\.absoluteString),
                       ["https://example.com/a", "http://example.org/b", "https://example.net/c"])
    }

    func testDuplicatesCollapsed() {
        let text = "https://example.com/a https://example.com/a HTTPS://EXAMPLE.COM/a"
        XCTAssertEqual(ClipboardLinkExtractor.links(in: text).count, 1)
    }

    func testNoURLs() {
        XCTAssertTrue(ClipboardLinkExtractor.links(in: "just some text INJECTED").isEmpty)
        XCTAssertTrue(ClipboardLinkExtractor.links(in: "").isEmpty)
    }

    func testNonHTTPSchemesIgnored() {
        let text = "mailto:someone@example.com ftp://example.com/f https://example.com/ok"
        XCTAssertEqual(ClipboardLinkExtractor.links(in: text).map(\.absoluteString), ["https://example.com/ok"])
    }
}
