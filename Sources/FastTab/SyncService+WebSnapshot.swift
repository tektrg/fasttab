import Foundation

// Feeds the experimental Web Reader (`WebReaderController`) the same tabs and bookmarks this
// Mac publishes to CloudKit. No-ops unless Settings > Experimental > Web Reader is on.
extension SyncService {
    func noteTabsForWebSnapshot(_ tabs: [BrowserSearchResult]) {
        guard WebReaderController.shared.isEnabled else { return }
        WebReaderController.shared.noteTabs(tabs)
    }

    func noteBookmarksForWebSnapshot(_ bookmarks: [BrowserSearchResult]) {
        guard WebReaderController.shared.isEnabled else { return }
        WebReaderController.shared.noteBookmarks(bookmarks)
    }
}
