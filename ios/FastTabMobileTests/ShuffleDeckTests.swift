import XCTest
import FastTabSync
import IndieTags
@testable import FastTabMobile

/// Shuffle after it left the tab bar: the Home deck lives for the app session and feeds the
/// Shuffle widget; the Highlights screen deals its visible highlights, one card each, and
/// never touches the widget.
@MainActor
final class ShuffleDeckTests: XCTestCase {

    // MARK: - Fixtures

    private func highlight(_ id: String, text: String? = nil, url: String = "https://a.com/1",
                           tags: [String] = []) -> ReaderHighlight {
        ReaderHighlight(id: id, urlKey: url, selectedText: text ?? "Text \(id)", color: .yellow,
                        serializedRange: "{}", urlString: url, tags: tags)
    }

    private func entries(_ highlights: [ReaderHighlight]) -> [HighlightFeedEntry] {
        HighlightFeedModel.entries(from: highlights, articleTitle: { "Article \($0.urlKey)" }, folderTags: { _ in [] })
    }

    private func deal(_ entries: [HighlightFeedEntry], seed: UInt64 = 1,
                      isSkipped: (String) -> Bool = { _ in false },
                      isHidden: (URL) -> Bool = { _ in false }) -> [RandomCardItem] {
        var rng = SplitMix64(seed: seed)
        return ShuffleDeck.buildHighlights(entries, isSkipped: isSkipped, isHidden: isHidden, using: &rng)
    }

    private func card(_ id: String) -> RandomCardItem {
        RandomCardItem(id: id, title: id, url: URL(string: "https://example.com/\(id)")!,
                       source: .highlight(highlight(id)))
    }

    private lazy var tenHighlights = entries((0..<10).map { highlight("h\($0)") })

    // MARK: - Highlights deck

    func testSameSeedDealsTheSameOrder() {
        XCTAssertEqual(deal(tenHighlights, seed: 42).map(\.id), deal(tenHighlights, seed: 42).map(\.id))
        XCTAssertNotEqual(deal(tenHighlights, seed: 42).map(\.id), deal(tenHighlights, seed: 7).map(\.id),
                          "a different seed shuffles differently")
    }

    func testEveryVisibleHighlightAppearsExactlyOnce() {
        let withDuplicate = tenHighlights + [tenHighlights[3]]
        let deck = deal(withDuplicate)
        XCTAssertEqual(deck.count, 10)
        XCTAssertEqual(Set(deck.map(\.id)), Set((0..<10).map { "highlight|h\($0)" }))
    }

    func testDeckIsHighlightCardsOnly() {
        let deck = deal(tenHighlights)
        XCTAssertFalse(deck.isEmpty)
        for card in deck {
            guard case .highlight(let highlight) = card.source else {
                return XCTFail("\(card.id) is not a highlight card")
            }
            XCTAssertEqual(card.id, "highlight|\(highlight.id)", "same id Home's Mac deck uses, so skips carry over")
            XCTAssertEqual(card.title, "Article https://a.com/1", "titled with the article, as on the Highlights screen")
            XCTAssertTrue(card.source.opensOnSwipeRight)
        }
        XCTAssertFalse(deck.contains { $0.id.hasPrefix("saved|") }, "no Read Again link cards")
    }

    func testHiddenArticlesAndTodaysSkipsAreLeftOut() {
        let pool = entries([highlight("keep"), highlight("hidden", url: "https://hidden.com/x"), highlight("skipped")])
        let deck = deal(pool, isSkipped: { $0 == "highlight|skipped" }, isHidden: { $0.host == "hidden.com" })
        XCTAssertEqual(deck.map(\.id), ["highlight|keep"])
    }

    func testEmptyAndSingleHighlightDecks() {
        XCTAssertEqual(deal([]), [])
        XCTAssertEqual(deal(entries([highlight("only")])).map(\.id), ["highlight|only"])
    }

    /// The pool is what the Highlights screen shows: tag/article filter and search applied first.
    func testDeckFollowsTheScreensFilterAndSearch() {
        let all = entries([
            highlight("a", text: "Decide faster", url: "https://a.com/1", tags: ["work"]),
            highlight("b", text: "Agents plan then act", url: "https://b.com/2", tags: ["work"]),
            highlight("c", text: "Nothing tagged", url: "https://a.com/1"),
        ])
        var filter = HighlightFeedFilter()
        filter.tagFilter.toggle(TagPath("work")!)
        let filtered = HighlightFeedModel.visibleEntries(all, filter: filter, searchText: "")
        XCTAssertEqual(Set(deal(filtered).map(\.id)), ["highlight|a", "highlight|b"])

        let searched = HighlightFeedModel.visibleEntries(all, filter: HighlightFeedFilter(), searchText: "agents")
        XCTAssertEqual(deal(searched).map(\.id), ["highlight|b"])
    }

    func testHostileHighlightTextIsPlainData() {
        let sentinel = "$(echo INJECTED)"
        let pool = HighlightFeedModel.entries(from: [highlight("x", text: sentinel)],
                                              articleTitle: { _ in sentinel }, folderTags: { _ in [] })
        let deck = deal(pool)
        XCTAssertEqual(deck.count, 1)
        XCTAssertEqual(deck[0].title, sentinel)
        guard case .highlight(let dealt) = deck[0].source else { return XCTFail("not a highlight card") }
        XCTAssertEqual(dealt.selectedText, sentinel)
    }

    // MARK: - Home deck session

    func testHomeDeckIsKeptUntilReshuffled() {
        let model = ShuffleDeckModel(source: .home, widget: { _ in })
        model.dealIfNeeded(context: AppMode.mac) { [card("a"), card("b")] }
        // Back to Read, then Shuffle again: a re-created view asks again and gets the same deck.
        model.dealIfNeeded(context: AppMode.mac) { [card("z")] }
        XCTAssertEqual(model.cards.map(\.id), ["a", "b"])

        model.remove { $0.id == "a" }
        model.dealIfNeeded(context: AppMode.mac) { [card("z")] }
        XCTAssertEqual(model.cards.map(\.id), ["b"], "a skip sticks across visits")

        model.deal([card("c")], context: AppMode.mac)
        XCTAssertEqual(model.cards.map(\.id), ["c"], "reshuffle replaces the deck")
    }

    func testHomeDeckRedealsAfterAModeSwitch() {
        let model = ShuffleDeckModel(source: .home, widget: { _ in })
        model.dealIfNeeded(context: AppMode.standalone) { [card("saved")] }
        model.dealIfNeeded(context: AppMode.mac) { [card("mac")] }
        XCTAssertEqual(model.cards.map(\.id), ["mac"], "reader-only and Mac decks draw from different pools")
    }

    // MARK: - Shuffle widget

    func testOnlyTheHomeDeckFeedsTheShuffleWidget() {
        var homeTops: [String?] = []
        let home = ShuffleDeckModel(source: .home, widget: { homeTops.append($0?.id) })
        home.deal([card("a"), card("b")], context: AppMode.mac)
        home.remove { $0.id == "b" } // top card unchanged: nothing to publish
        home.remove { $0.id == "a" }
        XCTAssertEqual(homeTops, ["a", nil])

        var highlightTops: [String?] = []
        let highlights = ShuffleDeckModel(source: .highlights(tenHighlights), widget: { highlightTops.append($0?.id) })
        highlights.deal(deal(tenHighlights), context: "highlights")
        highlights.remove { _ in true }
        XCTAssertEqual(highlightTops, [], "the Highlights deck never replaces the widget's card")
    }
}

/// Deterministic generator for shuffle tests (SplitMix64).
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
