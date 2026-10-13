import XCTest
import FastTabSync
import IndieComments
@testable import FastTabMobile

@MainActor
final class ReaderCommentThreadsTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("reader-comments-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Not in the shared highlight store, so nothing real is written there.
    private func highlight(id: String = UUID().uuidString, range: String) -> ReaderHighlight {
        ReaderHighlight(id: id, urlKey: "https://example.com/a", selectedText: "beta gamma", color: .yellow,
                        serializedRange: range)
    }

    func testAnchorTakesOffsetsAndContextFromTheRangeDescriptor() {
        let h = highlight(range: #"{"text":"beta gamma","start":6,"len":10,"cb":"Alpha ","ca":". Next"}"#)
        XCTAssertEqual(ReaderCommentThreads.anchor(for: h),
                       TextAnchor(from: 6, to: 16, quote: "beta gamma", contextBefore: "Alpha ", contextAfter: ". Next"))
    }

    func testAnchorFallsBackToTheSelectedTextForOldDescriptors() {
        let anchor = ReaderCommentThreads.anchor(for: highlight(range: "not json"))
        XCTAssertEqual(anchor, TextAnchor(from: 0, to: 10, quote: "beta gamma"))
    }

    func testDocIdIsAFileSafeHashOfTheArticle() {
        let id = ReaderCommentThreads.docId(urlKey: "https://example.com/a?b=c")
        XCTAssertEqual(id.count, 32)
        XCTAssertTrue(id.allSatisfy(\.isHexDigit))
        XCTAssertEqual(id, ReaderCommentThreads.docId(urlKey: "https://example.com/a?b=c"))
    }

    func testFirstCommentOpensTheThreadThenRepliesAndResolveRoundTrip() async throws {
        let threads = ReaderCommentThreads(directory: directory, linkThread: { _, _ in true })
        let h = highlight(range: #"{"text":"beta gamma","start":6,"len":10}"#)

        try await threads.post("first", on: h)
        try await threads.post("  second  ", on: h)
        try await threads.post("   ", on: h)
        var thread = try XCTUnwrap(threads.thread(for: h))
        XCTAssertEqual(thread.messages.map(\.text), ["first", "second"])
        XCTAssertEqual(thread.opener.by, ReaderCommentThreads.me)
        XCTAssertEqual(thread.state, .open)

        try await threads.setResolved(true, on: h)
        XCTAssertEqual(threads.thread(for: h)?.state, .resolved)
        try await threads.post("again", on: h)
        thread = try XCTUnwrap(threads.thread(for: h))
        XCTAssertEqual(thread.state, .open, "a reply reopens a resolved thread")

        // Written in MDLY's format: the log reads back through the shared library.
        let events = try CommentLog(directory: directory).events(docId: ReaderCommentThreads.docId(urlKey: h.urlKey))
        XCTAssertEqual(events.count, 4, "opened, replied, resolved, replied")
    }

    func testDeletingTheHighlightDeletesItsThread() async throws {
        let threads = ReaderCommentThreads(directory: directory, linkThread: { _, _ in true })
        let h = highlight(range: #"{"text":"beta gamma","start":6,"len":10}"#)
        try await threads.post("note", on: h)
        let threadId = try XCTUnwrap(threads.thread(for: h)?.id)

        await threads.deleteThreads(of: [h])
        XCTAssertNil(threads.thread(for: h))
        let store = CommentStore(log: CommentLog(directory: directory))
        let deleted = try await store.thread(id: threadId, docId: ReaderCommentThreads.docId(urlKey: h.urlKey), text: "")
        XCTAssertEqual(deleted?.state, .deleted)
    }

    func testOldStoredHighlightsStillDecodeWithoutAThread() throws {
        let json = #"{"id":"x","urlKey":"k","selectedText":"t","color":"yellow","serializedRange":"{}","createdAt":0}"#
        let decoded = try JSONDecoder().decode(ReaderHighlight.self, from: Data(json.utf8))
        XCTAssertNil(decoded.commentThreadId)
        XCTAssertEqual(decoded.replacingCommentThreadId("t1").commentThreadId, "t1")
        XCTAssertEqual(decoded.replacingCommentThreadId("t1").replacingTags(["a"]).commentThreadId, "t1")
    }

    func testFeedSearchFindsCommentText() {
        let h = highlight(range: "{}")
        let entries = HighlightFeedModel.entries(
            from: [h], articleTitle: { _ in "Title" }, folderTags: { _ in [] }, comments: { _ in ["remember the quarterly plan"] })
        XCTAssertEqual(HighlightFeedModel.visibleEntries(entries, filter: HighlightFeedFilter(), searchText: "quarterly").count, 1)
        XCTAssertEqual(HighlightFeedModel.visibleEntries(entries, filter: HighlightFeedFilter(), searchText: "absent").count, 0)
    }

    func testAThreadOpenedForAHighlightDeletedMeanwhileIsNotLeftBehind() async throws {
        let threads = ReaderCommentThreads(directory: directory, linkThread: { _, _ in false })
        let h = highlight(range: #"{"text":"beta gamma","start":6,"len":10}"#)
        try await threads.post("note", on: h)
        XCTAssertNil(threads.thread(for: h))
        let store = CommentStore(log: CommentLog(directory: directory))
        let live = try await store.threads(docId: ReaderCommentThreads.docId(urlKey: h.urlKey), text: "")
        XCTAssertTrue(live.isEmpty)
    }

    func testHighlightPayloadRoundTripsThroughSyncEncoding() throws {
        let h = ReaderHighlight(id: "h", urlKey: "k", selectedText: "t", color: .pink, serializedRange: "{}",
                                createdAt: Date(timeIntervalSince1970: 1_760_000_000), title: "T", urlString: "https://k",
                                tags: ["work/ssv"], commentThreadId: "c1")
        let payload = try ReaderSyncBridge.encoder.encode(h)
        XCTAssertEqual(try JSONDecoder().decode(ReaderHighlight.self, from: payload), h)
        XCTAssertEqual(try ReaderSyncBridge.encoder.encode(h), payload, "same highlight, same bytes")
        XCTAssertEqual(ReaderCommentThreads.docId(urlKey: "k"), ReaderCommentDocID.forArticle(urlKey: "k"))
    }
}
