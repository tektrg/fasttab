import XCTest
@testable import FastTabMobile

final class XArticleExtractorTests: XCTestCase {

    private let url = URL(string: "https://x.com/XCreators/article/2011957172821737574")!

    /// Shape captured from api.fxtwitter.com for a real Article post (trimmed).
    private var response: [String: Any] {
        [
            "tweet": [
                "author": ["name": "Creators", "screen_name": "XCreators"],
                "article": [
                    "title": "The ultimate guide",
                    "preview_text": "Level up with X Articles",
                    "cover_media": ["media_info": ["original_img_url": "https://pbs.twimg.com/media/cover.jpg"]],
                    "media_entities": [
                        ["media_id": "111", "media_info": ["original_img_url": "https://pbs.twimg.com/media/inline.jpg"]]
                    ],
                    "content": [
                        "blocks": [
                            ["type": "unstyled", "text": "Hello bold & world", "inlineStyleRanges": [["style": "Bold", "offset": 6, "length": 4]], "entityRanges": []],
                            ["type": "header-two", "text": "Section", "inlineStyleRanges": [], "entityRanges": []],
                            ["type": "unordered-list-item", "text": "one", "inlineStyleRanges": [], "entityRanges": []],
                            ["type": "unordered-list-item", "text": "two link", "inlineStyleRanges": [], "entityRanges": [["key": 1, "offset": 4, "length": 4]]],
                            ["type": "atomic", "text": " ", "inlineStyleRanges": [], "entityRanges": [["key": 0, "offset": 0, "length": 1]]]
                        ],
                        "entityMap": [
                            ["key": "0", "value": ["type": "MEDIA", "data": ["mediaItems": [["mediaId": "111"]]]]],
                            ["key": "1", "value": ["type": "LINK", "data": ["url": "https://example.com/?a=1&b=2"]]]
                        ]
                    ]
                ]
            ]
        ]
    }

    func testArticleBodyTextIsRendered() throws {
        let article = try XCTUnwrap(XArticleExtractor.article(fromAPIResponse: response, url: url))
        XCTAssertEqual(article.title, "The ultimate guide")
        XCTAssertEqual(article.byline, "Creators @XCreators")
        XCTAssertTrue(article.content.contains("<p>Hello <strong>bold</strong> &amp; world</p>"))
        XCTAssertTrue(article.content.contains("<h2>Section</h2>"))
        XCTAssertTrue(article.content.contains("<ul><li>one</li><li>two <a href=\"https://example.com/?a=1&amp;b=2\">link</a></li></ul>"))
    }

    func testArticleImagesCoverFirstThenInline() throws {
        let article = try XCTUnwrap(XArticleExtractor.article(fromAPIResponse: response, url: url))
        let cover = try XCTUnwrap(article.content.range(of: "cover.jpg"))
        let inline = try XCTUnwrap(article.content.range(of: "inline.jpg"))
        XCTAssertTrue(cover.lowerBound < inline.lowerBound)
    }

    func testInlineStyleOffsetsAreUTF16() {
        // "😀" is 2 UTF-16 units, so "hi" starts at offset 3.
        let block: [String: Any] = ["inlineStyleRanges": [["style": "Italic", "offset": 3, "length": 2]]]
        XCTAssertEqual(XArticleExtractor.inlineHTML(text: "😀 hi", block: block, entities: [:]), "😀 <em>hi</em>")
    }

    func testResponseWithoutArticleReturnsNil() {
        XCTAssertNil(XArticleExtractor.article(fromAPIResponse: ["tweet": ["text": "hi"]], url: url))
    }

    func testArticleWithOnlyImagesReturnsNil() {
        var json = response
        var tweet = json["tweet"] as! [String: Any]
        var article = tweet["article"] as! [String: Any]
        article["content"] = ["blocks": [["type": "atomic", "text": " ", "entityRanges": [["key": 0, "offset": 0, "length": 1]]]],
                              "entityMap": [["key": "0", "value": ["type": "MEDIA", "data": ["mediaItems": [["mediaId": "111"]]]]]]]
        tweet["article"] = article
        json["tweet"] = tweet
        XCTAssertNil(XArticleExtractor.article(fromAPIResponse: json, url: url))
    }

    func testURLRouting() {
        XCTAssertTrue(XArticleExtractor.isArticleURL(url))
        XCTAssertFalse(XArticleExtractor.isArticleURL(URL(string: "https://x.com/jack/status/20")!))
        XCTAssertFalse(XArticleExtractor.isArticleURL(URL(string: "https://example.com/u/article/1")!))
        XCTAssertEqual(XArticleExtractor.postReference(from: url)?.id, "2011957172821737574")
        XCTAssertEqual(XArticleExtractor.postReference(from: URL(string: "https://x.com/jack/status/20?s=1")!)?.handle, "jack")
        XCTAssertNil(XArticleExtractor.postReference(from: URL(string: "https://x.com/i/article/123")!))
    }

    func testLinkOnlyDetection() {
        XCTAssertTrue(XArticleExtractor.isLinkOnly("https://t.co/8CxfhKnGr2"))
        XCTAssertFalse(XArticleExtractor.isLinkOnly("Read this https://t.co/8CxfhKnGr2"))
        XCTAssertFalse(XArticleExtractor.isLinkOnly("just setting up my twttr"))
        XCTAssertFalse(XArticleExtractor.isLinkOnly(""))
    }

    func testMayLinkToArticleMatchesCaptionedArticlePosts() {
        XCTAssertTrue(XArticleExtractor.mayLinkToArticle("https://t.co/8CxfhKnGr2"))
        XCTAssertTrue(XArticleExtractor.mayLinkToArticle("A long caption about the article. https://t.co/Vr3NPgXS3N"))
        XCTAssertFalse(XArticleExtractor.mayLinkToArticle("just setting up my twttr"))
    }

    @MainActor
    func testOnlyXArticleFailureUsesSafariReader() {
        let vm = ReaderViewModel(url: url, title: "t", statsRecorder: .isolatedForTests())
        vm.loadState = .failed(ReaderExtractor.ExtractionError.xArticleUnavailable)
        XCTAssertTrue(vm.needsSafariReader)
        vm.loadState = .failed(ReaderExtractor.ExtractionError.noContent)
        XCTAssertFalse(vm.needsSafariReader)
        vm.loadState = .idle
        XCTAssertFalse(vm.needsSafariReader)
    }
}
