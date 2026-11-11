import Foundation
import Combine
import IndieCommandBar

/// Agent Bar's fixed page: the full list, always first.
enum AgentBuiltinPage: String, CommandBarBuiltinPage {
    case all
}

/// A page of the strip above the agent list: All, a saved view, or "＋ New view".
typealias AgentPage = CommandBarPage<AgentBuiltinPage>

/// The saved-view editor while open.
struct AgentViewEditorState: Equatable {
    var draft: AgentViewDraft
    let isNew: Bool
    /// Where Cancel returns to (a new view's editor sits on the New view page).
    let returnPage: AgentPage
    var isConfirmingDelete = false
}

/// Which page the agent list shows, the saved views (`AgentSavedViewStore`), and the editor.
/// Owns every saved-view mutation; `onPageChange` tells the panel to rebuild its list.
@MainActor
final class AgentPagesModel: ObservableObject {
    let store: AgentSavedViewStore
    @Published private(set) var activePage: AgentPage = .builtin(.all)
    @Published var editor: AgentViewEditorState?
    /// Called after the shown page or the active view's definition changed.
    var onPageChange: (() -> Void)?
    /// Agents a draft would show right now (nil = unknown, e.g. no feed yet).
    var matchCount: ((AgentSavedView) -> Int?)?

    private var storeObservation: AnyCancellable?

    init(store: AgentSavedViewStore = AgentSavedViewStore()) {
        self.store = store
        storeObservation = store.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    static let builtins: [AgentBuiltinPage] = [.all]

    /// Typed in the search box + Return: opens the editor for a new view. With no saved views yet
    /// this is how the first one is made (the strip, and its "+ New view" tab, only shows once one exists).
    static let newViewCommand = "/view"

    /// `/view` (any case, surrounding spaces ignored).
    static func isNewViewCommand(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == newViewCommand
    }

    /// The strip and page switching (⌘1…⌘9, swipe) exist only once a view is saved.
    var hasSavedViews: Bool { !store.views.isEmpty }

    /// Swipe order: All, saved views, New view.
    var orderedPages: [AgentPage] {
        AgentPage.ordered(builtins: Self.builtins, customIDs: store.views.map(\.id))
    }

    /// The saved view the list is filtered by; nil on All (and while a new view is being built).
    var activeView: AgentSavedView? {
        activePage.customID.flatMap(store.view(id:))
    }

    var tabs: [CommandBarPageTab<AgentBuiltinPage>] {
        CommandBarPageTab.tabs(for: orderedPages) { page in
            switch page {
            case .builtin(.all): return ("All", "list.bullet", "All agents")
            case .custom(let id):
                let view = store.view(id: id)
                return (view?.name ?? "View", view?.iconName ?? AgentViewCriteria.defaultIconName, nil)
            case .newView: return ("New view", "plus", "New view")
            }
        }
    }

    // MARK: Switching

    /// Shows `page`; New view opens the editor for a new view instead.
    func select(_ page: AgentPage) {
        if page == .newView { beginNew(); return }
        guard orderedPages.contains(page) else { return }
        editor = nil
        setActive(page)
    }

    /// ⌘1…⌘9: the Nth page (New view excluded). False when there is no such page.
    @discardableResult
    func selectNumbered(_ number: Int) -> Bool {
        guard hasSavedViews, let target = AgentPage.numberedShortcutTarget(number, in: orderedPages) else { return false }
        select(target)
        return true
    }

    /// One page forward (positive) or back, clamped at both ends. False at an end.
    @discardableResult
    func step(_ step: Int) -> Bool {
        guard hasSavedViews, let target = AgentPage.neighbor(of: activePage, step: step, in: orderedPages) else { return false }
        select(target)
        return true
    }

    private func setActive(_ page: AgentPage) {
        guard page != activePage else { return }
        activePage = page
        onPageChange?()
    }

    // MARK: Editor

    func beginNew() {
        guard editor?.isNew != true else { return }
        let returnPage = activePage == .newView ? .builtin(.all) : activePage
        editor = AgentViewEditorState(draft: .new(), isNew: true, returnPage: returnPage)
        setActive(.newView)
    }

    func beginEdit(id: UUID, confirmingDelete: Bool = false) {
        guard let view = store.view(id: id) else { return }
        let returnPage = activePage == .newView ? AgentPage.builtin(.all) : activePage
        editor = AgentViewEditorState(draft: AgentViewDraft(view), isNew: false, returnPage: returnPage, isConfirmingDelete: confirmingDelete)
        setActive(.custom(id))
    }

    func cancelEditor() {
        guard let state = editor else { return }
        editor = nil
        setActive(orderedPages.contains(state.returnPage) ? state.returnPage : .builtin(.all))
    }

    /// Saves a valid draft and shows that view. False (editor stays) when invalid.
    @discardableResult
    func saveEditor() -> Bool {
        guard let state = editor, state.draft.isValid else { return false }
        let view = state.draft.view
        if state.isNew { store.add(view) } else { store.update(view) }
        editor = nil
        if activePage == .custom(view.id) { onPageChange?() } else { setActive(.custom(view.id)) }
        return true
    }

    func deleteView(id: UUID) {
        store.delete(id: id)
        if editor?.draft.id == id { editor = nil }
        if activePage == .custom(id) { setActive(.builtin(.all)) }
    }
}
