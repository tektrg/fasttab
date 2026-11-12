import Foundation

/// What a Shuffle deck deals from.
enum ShuffleSource {
    /// Read's Shuffle button: saved links (reader only) or Mac bookmarks, tabs and highlights,
    /// plus Read Again links. The only deck the Shuffle widget mirrors.
    case home
    /// The Highlights screen's Shuffle button: exactly the highlights the screen showed when it
    /// opened (tag/article filter and search applied), one card each.
    case highlights([HighlightFeedEntry])

    var feedsShuffleWidget: Bool {
        if case .home = self { return true }
        return false
    }
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
    private let widget: WidgetSink

    init(source: ShuffleSource, widget: @escaping WidgetSink = { WidgetSnapshotPublisher.shared.shuffleTopCardChanged($0) }) {
        self.source = source
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

    func remove(where shouldRemove: (RandomCardItem) -> Bool) {
        cards.removeAll(where: shouldRemove)
    }
}
