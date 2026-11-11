import SwiftUI
import IndieCommandBar

/// Fast Tab's two swipe actions on a result row: swipe right (→) copies the
/// link, swipe left (←) removes the result. The shared swipe engine reports an
/// edge; `kind(for:)` says which of these Fast Tab runs.
enum FastTabSwipeActions {
    enum Kind: Equatable { case copyLink, remove }

    static var copyLink: CommandBarRowAction { CommandBarRowAction(
        id: "copyLink", title: "Copy Link", symbol: "link", swipeEdge: .leading
    ) }
    static var remove: CommandBarRowAction { CommandBarRowAction(
        id: "remove", title: "Remove", symbol: "checkmark", role: .destructive, swipeEdge: .trailing, tint: .green
    ) }
    static var all: [CommandBarRowAction] { [copyLink, remove] }

    static let copiedToastText = "Link copied"

    static func action(for edge: CommandBarSwipeEdge) -> CommandBarRowAction? {
        all.first { $0.swipeEdge == edge }
    }

    static func kind(for edge: CommandBarSwipeEdge) -> Kind {
        edge == .trailing ? .remove : .copyLink
    }
}
