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

    /// The page strip shows once a view is saved, unless the search box is composing (Tab-tag) or
    /// in New worker mode. With zero views the panel is exactly the plain list (no strip height).
    var showsPageStrip: Bool {
        pages.hasSavedViews && taggedAgentID == nil && newWorker == nil
    }

    /// `/view` + Return, or "New view" on the "+" button's menu: opens the new-view editor.
    func beginNewView() {
        guard !isCardOpen, routingState == nil else { return }
        removeTag()
        closePeek()
        newWorker = nil
        query = ""
        pages.beginNew()
    }

    /// Return with `/view` in the box. Not while Tab-tagged or in New worker mode (the box is a
    /// message / folder filter there).
    func beginNewViewIfCommand() -> Bool {
        guard newWorker == nil, taggedAgentID == nil, AgentPagesModel.isNewViewCommand(query) else { return false }
        beginNewView()
        return true
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
