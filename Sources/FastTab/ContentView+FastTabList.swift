import SwiftUI

// FastTab List ↔ Bookmarks bridges on command-bar rows (row button, ⌘S / ⌘D).
// Kept out of `body` on purpose (see the ContentView type-checker memo).

extension ContentView {
    /// The row's bridge, if it offers one: "Read later" on web tabs/bookmarks,
    /// "Move to Bookmarks" on FastTab List items.
    func performFastTabListBridge(_ result: BrowserSearchResult) {
        switch FastTabListRowBridge.forResult(result) {
        case .readLater:
            let saved = appState.browserService.readLater(result)
            showToast(saved ? "Added to FastTab List" : "Can't add this link")
        case .moveToBookmarks:
            appState.browserService.moveFastTabListItemToBookmarks(result) { folderLabel in
                showToast(folderLabel.map { "Moved to \($0)" } ?? "Couldn't add the bookmark")
            }
        case nil:
            break
        }
    }

    /// ⌘S = Read later, ⌘D = Move to Bookmarks, on the selected row. Returns whether the
    /// key was handled (only when the row offers that bridge).
    func handleFastTabListShortcut(keyCode: UInt16) -> Bool {
        let wanted: FastTabListRowBridge
        switch keyCode {
        case Self.readLaterKeyCode: wanted = .readLater
        case Self.moveToBookmarksKeyCode: wanted = .moveToBookmarks
        default: return false
        }
        let items = displayedItems
        guard items.indices.contains(appState.selectedIndex),
              let result = items[appState.selectedIndex].result,
              FastTabListRowBridge.forResult(result) == wanted else { return false }
        performFastTabListBridge(result)
        return true
    }

    static let readLaterKeyCode: UInt16 = 1        // S
    static let moveToBookmarksKeyCode: UInt16 = 2  // D
}
