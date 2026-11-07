import SwiftUI

// FastTab List ↔ Bookmarks bridges on command-bar rows (row button, ⌘S / ⌘D).
// Kept out of `body` on purpose (see the ContentView type-checker memo).

extension ContentView {
    /// The row's bridge, if it offers one: "Read later" on web tabs/bookmarks,
    /// "Move to Bookmarks" on FastTab List items.
    func performFastTabListBridge(_ result: BrowserSearchResult) {
        switch FastTabListRowBridge.forResult(result) {
        case .sendToList:
            let saved = appState.browserService.readLater(result)
            showToast(saved ? "Sent to FastTab List" : "Can't add this link")
        case .sendToListAndClose:
            // Close only once the link is safely in the list.
            guard appState.browserService.readLater(result) else {
                showToast("Can't add this link")
                return
            }
            showToast("Sent to FastTab List")
            performRemove(result)
        case .moveToBookmarks:
            appState.browserService.moveFastTabListItemToBookmarks(result) { folderLabel in
                showToast(folderLabel.map { "Moved to \($0)" } ?? "Couldn't add the bookmark")
            }
        case nil:
            break
        }
    }

    /// Stack slot "Send to FastTab List & Close": saves the link, then closes the slot's tab.
    func sendStackSlotToFastTabList(_ slot: OrderedTabSlot) {
        guard FastTabListStore.shared.readLater(url: slot.url, title: slot.title) else {
            showToast("Can't add this link")
            return
        }
        showToast("Sent to FastTab List")
        myOrderStore.closeSlot(slot.slotID)
    }

    /// ⌘S = Send to FastTab List (and close, on a tab), ⌘D = Move to Bookmarks, on the selected row. Returns whether the
    /// key was handled (only when the row offers that bridge).
    func handleFastTabListShortcut(keyCode: UInt16) -> Bool {
        guard keyCode == Self.readLaterKeyCode || keyCode == Self.moveToBookmarksKeyCode else { return false }
        let items = displayedItems
        guard items.indices.contains(appState.selectedIndex),
              let result = items[appState.selectedIndex].result,
              let bridge = FastTabListRowBridge.forResult(result),
              bridge.sendsToList == (keyCode == Self.readLaterKeyCode) else { return false }
        performFastTabListBridge(result)
        return true
    }

    static let readLaterKeyCode: UInt16 = 1        // S
    static let moveToBookmarksKeyCode: UInt16 = 2  // D
}
