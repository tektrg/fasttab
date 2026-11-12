import XCTest
import FastTabSync
import IndieTags
@testable import FastTabMobile

/// Shuffle after it left the tab bar: the Home deck lives for the app session and feeds the
/// Shuffle widget; the Highlights screen deals every visible highlight, one card each, and
/// never touches the widget or the shared day-skips.
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

    private func deal(_ entries: [HighlightFeedEntry], seed: UInt64 = 1) -> [RandomCardItem] {
        var rng = SplitMix64(seed: seed)
        return ShuffleDeck.buildHighlights(entries, using: &rng)
    }

    /// Day-skip and "Don't Surface" stores in a throwaway folder, never the app's own.
    private func makeStores() -> (skips: RandomFeedSkipStore, hidden: RandomFeedHiddenStore) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ShuffleDeckTests-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return (RandomFeedSkipStore(customFileURL: dir.appendingPathComponent("skips.json")),
                RandomFeedHiddenStore(customFileURL: dir.appendingPathComponent("hidden.json")))
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

    /// Every highlight on screen is dealt, even one skipped today (in either deck) or from an
    /// article set to "Don't Surface": those filter Home's deck only.
    func testSkippedAndHiddenHighlightsStillAppear() {
        let stores = makeStores()
        stores.skips.skip("highlight|skipped")
        let hiddenURL = URL(string: "https://hidden.com/x")!
        stores.hidden.hide(url: hiddenURL)
        XCTAssertTrue(stores.skips.isSkipped("highlight|skipped"))
        XCTAssertTrue(stores.hidden.isHidden(url: hiddenURL))

        let pool = entries([highlight("keep"), highlight("hidden", url: hiddenURL.absoluteString), highlight("skipped")])
        let model = ShuffleDeckModel(source: .highlights(pool), skipStore: stores.skips, widget: { _ in })
        model.dealIfNeeded(context: "highlights") { deal(pool) }
        XCTAssertEqual(Set(model.cards.map(\.id)), ["highlight|keep", "highlight|hidden", "highlight|skipped"])
    }

    func testLeftSwipeInTheHighlightsDeckIsNotADaySkip() {
        let stores = makeStores()
        let model = ShuffleDeckModel(source: .highlights(tenHighlights), skipStore: stores.skips, widget: { _ in })
        model.deal(deal(tenHighlights), context: "highlights")
        let top = model.cards[0]
        model.skip(top)
        XCTAssertFalse(model.cards.contains(top), "moves past it in this deal")
        XCTAssertFalse(stores.skips.isSkipped(top.id), "Home's deck keeps it")
    }

    func testHomeLeftSwipeIsStillADaySkip() {
        let stores = makeStores()
        let model = ShuffleDeckModel(source: .home, skipStore: stores.skips, widget: { _ in })
        model.deal([card("a"), card("b")], context: AppMode.mac)
        model.skip(card("a"))
        XCTAssertEqual(model.cards.map(\.id), ["b"])
        XCTAssertTrue(stores.skips.isSkipped("a"))
    }

    func testExhaustedHighlightsDeckRedealsEveryHighlightWithoutTouchingDaySkips() {
        let stores = makeStores()
        stores.skips.skip("bookmark|from-home") // a Home skip made earlier today
        let model = ShuffleDeckModel(source: .highlights(tenHighlights), skipStore: stores.skips, widget: { _ in })
        model.deal(deal(tenHighlights), context: "highlights")
        for card in model.cards { model.skip(card) }
        XCTAssertTrue(model.cards.isEmpty)

        model.shuffleAgain(context: "highlights") { deal(tenHighlights, seed: 9) }
        XCTAssertEqual(model.cards.count, 10)
        XCTAssertEqual(Set(model.cards.map(\.id)), Set((0..<10).map { "highlight|h\($0)" }))
        XCTAssertTrue(stores.skips.isSkipped("bookmark|from-home"), "Home's skips survive")
        XCTAssertFalse((0..<10).contains { stores.skips.isSkipped("highlight|h\($0)") })
    }

    func testHomeShuffleAgainStillBringsBackTodaysSkips() {
        let stores = makeStores()
        let model = ShuffleDeckModel(source: .home, skipStore: stores.skips, widget: { _ in })
        model.deal([card("a")], context: AppMode.mac)
        model.skip(card("a"))
        model.shuffleAgain(context: AppMode.mac) { [card("a")] }
        XCTAssertFalse(stores.skips.isSkipped("a"))
        XCTAssertEqual(model.cards.map(\.id), ["a"])
    }

    func testOnlyTheHomeDeckShowsTheSwipeTipAndDontSurface() {
        XCTAssertTrue(ShuffleSource.home.showsSwipeTip)
        XCTAssertTrue(ShuffleSource.home.offersDontSurface)
        XCTAssertFalse(ShuffleSource.highlights(tenHighlights).showsSwipeTip, "swiping right opens, not moves")
        XCTAssertFalse(ShuffleSource.highlights(tenHighlights).offersDontSurface, "the deck ignores Don't Surface")
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

    // MARK: - Deleted highlights

    private func linkCard(_ id: String) -> RandomCardItem {
        let link = SavedOnIPhoneLink(id: id, url: "https://example.com/\(id)", title: id, savedAt: Date())
        return RandomCardItem(id: "saved|\(id)", title: id, url: URL(string: link.url)!, source: .savedLink(link))
    }

    /// Deleted in the reader (or anywhere) while the deck is open: its card leaves the deck,
    /// everything else stays in order, and the top card only changes if it was the deleted one.
    func testDeletedHighlightLeavesTheDeckInPlace() {
        var tops: [String?] = []
        let model = ShuffleDeckModel(source: .home, widget: { tops.append($0?.id) })
        model.deal([card("h1"), linkCard("l1"), card("h2"), card("h3")], context: AppMode.mac)

        model.pruneHighlights(existing: ["h1", "h3"])
        XCTAssertEqual(model.cards.map(\.id), ["h1", "saved|l1", "h3"], "link cards are never pruned")
        XCTAssertEqual(tops, ["h1"], "top card unchanged")

        model.pruneHighlights(existing: ["h3"])
        XCTAssertEqual(model.cards.map(\.id), ["saved|l1", "h3"])
        XCTAssertEqual(tops, ["h1", "saved|l1"], "the deleted top card gives way to the next")
    }

    func testHighlightsDeckPrunesDeletedHighlightsToo() {
        let model = ShuffleDeckModel(source: .highlights(tenHighlights), widget: { _ in })
        let dealt = deal(tenHighlights)
        model.deal(dealt, context: "highlights")
        let gone = dealt[4]
        guard case .highlight(let goneHighlight) = gone.source else { return XCTFail("not a highlight card") }
        let remaining = Set(tenHighlights.map(\.highlight.id)).subtracting([goneHighlight.id])

        model.pruneHighlights(existing: remaining)
        XCTAssertEqual(model.cards.map(\.id), dealt.map(\.id).filter { $0 != gone.id })
        XCTAssertEqual(model.cards.first?.id, dealt[0].id)

        model.pruneHighlights(existing: remaining)
        XCTAssertEqual(model.cards.count, 9, "nothing else to prune")
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
