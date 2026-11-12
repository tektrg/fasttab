import Foundation

/// What a Shuffle deck deals from.
enum ShuffleSource {
    /// Read's Shuffle button: saved links (reader only) or Mac bookmarks, tabs and highlights,
    /// plus Read Again links. The only deck the Shuffle widget mirrors.
    case home
    /// The Highlights screen's Shuffle button: exactly the highlights the screen showed when it
    /// opened (tag/article filter and search applied), one card each. Today's skips and
    /// "Don't Surface" never thin it out, and a skip here only moves past the card.
    case highlights([HighlightFeedEntry])

    private var isHome: Bool {
        if case .home = self { return true }
        return false
    }

    var feedsShuffleWidget: Bool { isHome }
    /// A left swipe skips until tomorrow (`RandomFeedSkipStore`); Home's deck only.
    var usesDaySkips: Bool { isHome }
    /// The card menu's "Don't Surface…": Home's pool honours it, a Highlights deck ignores it.
    var offersDontSurface: Bool { isHome }
    /// `ShuffleSwipeTip` says swipe right moves or saves; on a Highlights deck it opens.
    var showsSwipeTip: Bool { isHome }
}

/// The cards of one Shuffle deck, held outside the view so the deck outlives it: the app owns
/// the Home deck for the whole session (back to Read, Shuffle again = same deck); each Highlights
/// Shuffle screen owns a fresh one. Dealing (the pools) stays in `RandomLinksView`.
@MainActor
final class ShuffleDeckModel: ObservableObject {
    typealias WidgetSink = @MainActor (RandomCardItem?) -> Void

    let source: ShuffleSource
    @Published private(set) var cards: [RandomCardItem] = [] {
        didSet {
            // The Shuffle widget mirrors the Home deck's top card, never a Highlights deck's.
            guard source.feedsShuffleWidget, cards.first?.id != oldValue.first?.id else { return }
            widget(cards.first)
        }
    }
    /// What the current deck was dealt for (the app mode, for Home); a change re-deals.
    private var dealtContext: AnyHashable?
    private let skipStore: RandomFeedSkipStore
    private let widget: WidgetSink

    init(
        source: ShuffleSource,
        skipStore: RandomFeedSkipStore? = nil,
        widget: @escaping WidgetSink = { WidgetSnapshotPublisher.shared.shuffleTopCardChanged($0) }
    ) {
        self.source = source
        // Resolved here, not as a default argument: `.shared` is main-actor isolated.
        self.skipStore = skipStore ?? .shared
        self.widget = widget
    }

    /// Deals only on the first visit, or when `context` changed since the last deal.
    func dealIfNeeded(context: AnyHashable, _ makeDeck: () -> [RandomCardItem]) {
        guard dealtContext != context else { return }
        deal(makeDeck(), context: context)
    }

    /// A new deal (reshuffle), replacing whatever is left.
    func deal(_ deck: [RandomCardItem], context: AnyHashable) {
        dealtContext = context
        cards = deck
    }

    /// Swipe left. Home: gone until tomorrow (shared day-skips). Highlights: past it for this deal only.
    func skip(_ card: RandomCardItem) {
        if source.usesDaySkips { skipStore.skip(card.id) }
        remove { $0.id == card.id }
    }

    /// "Shuffle again" on a finished deck. Home brings today's skips back first; a Highlights
    /// deck just deals all its highlights again and leaves the shared day-skips alone.
    func shuffleAgain(context: AnyHashable, _ makeDeck: () -> [RandomCardItem]) {
        if source.usesDaySkips { skipStore.resetToday() }
        deal(makeDeck(), context: context)
    }

    func remove(where shouldRemove: (RandomCardItem) -> Bool) {
        cards.removeAll(where: shouldRemove)
    }
}
