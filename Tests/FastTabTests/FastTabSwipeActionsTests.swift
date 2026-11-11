import SwiftUI
import Testing
import IndieCommandBar
@testable import FastTab

/// Which swipe runs which Fast Tab action, and what the user is told.
struct FastTabSwipeActionsTests {
    @Test func leftSwipeRemovesRightSwipeCopies() {
        #expect(FastTabSwipeActions.kind(for: CommandBarSwipeDirection.left.revealedEdge) == .remove)
        #expect(FastTabSwipeActions.kind(for: CommandBarSwipeDirection.right.revealedEdge) == .copyLink)
    }

    @Test func tailIconsMatchTheOldLook() {
        let remove = FastTabSwipeActions.action(for: .trailing)
        #expect(remove?.symbol == "checkmark")
        #expect(remove?.tint == .green)
        #expect(remove?.role == .destructive)
        let copy = FastTabSwipeActions.action(for: .leading)
        #expect(copy?.symbol == "link")
        #expect(copy?.tint == nil)   // accent color
    }

    @Test func copyToastText() {
        #expect(FastTabSwipeActions.copiedToastText == "Link copied")
    }
}
