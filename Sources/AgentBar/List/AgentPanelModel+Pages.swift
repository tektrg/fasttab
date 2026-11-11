import Foundation
import Combine

/// Saved-view pages (`AgentPagesModel`): switching pages re-filters the list and starts the
/// selection at its first row, like typing does.
extension AgentPanelModel {
    func wirePages() {
        pagesObservation = pages.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        pages.onPageChange = { [weak self] in self?.pageDidChange() }
        pages.matchCount = { [weak self] view in self?.agentCount(in: view) }
    }

    /// The page strip shows unless the search box is composing (Tab-tag) or in New worker mode.
    var showsPageStrip: Bool {
        taggedAgentID == nil && newWorker == nil
    }

    /// ⌘1…⌘9 and swipes are ignored while the editor or a card owns the panel.
    var canSwitchPages: Bool {
        showsPageStrip && pages.editor == nil && !isCardOpen && peek == nil
    }

    /// Project names in the current feed, for the editor's project chips.
    var projectOptions: [String] {
        Array(Set((snapshot?.agents ?? []).compactMap(\.projectName).filter { !$0.isEmpty }))
    }
}
