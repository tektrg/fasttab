import Foundation
import Combine
import IndieCommandBar

/// A page of the strip above the agent list: All (always first), a saved view, or "＋ New view".
/// Shown with the shared `CommandBarViewTab` model; `id` is the tab id.
enum AgentPage: Hashable {
    case all
    case custom(UUID)
    case newView

    var id: String {
        switch self {
        case .all: return "all"
        case .custom(let id): return "custom:" + id.uuidString
        case .newView: return "newView"
        }
    }

    var customID: UUID? {
        if case .custom(let id) = self { return id }
        return nil
    }
}

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
    @Published private(set) var activePage: AgentPage = .all
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

    /// Typed in the search box + Return: opens the editor for a new view. With no saved views yet
    /// this is how the first one is made (the strip, and its "+ New view" tab, only shows once one exists).
    static let newViewCommand = "/view"

    /// `/view` (any case, surrounding spaces ignored).
    static func isNewViewCommand(_ text: String) -> Bool {
        AgentBarCommands.exact(text) == AgentBarCommands.newView
    }

    /// The strip and page switching (⌘1…⌘9, swipe) exist only once a view is saved.
    var hasSavedViews: Bool { !store.views.isEmpty }

    /// Swipe order: All, saved views, New view.
    var orderedPages: [AgentPage] {
        [.all] + store.views.map { .custom($0.id) } + [.newView]
    }

    /// The saved view the list is filtered by; nil on All (and while a new view is being built).
    var activeView: AgentSavedView? {
        activePage.customID.flatMap(store.view(id:))
    }

    var tabs: [CommandBarViewTab] {
        let ordered = orderedPages
        let numbers = CommandBarViewOrder.shortcutNumbers(for: ordered) { $0 != .newView }
        return zip(ordered, numbers).map { page, number in
            let title: String, symbol: String, base: String
            switch page {
            case .all: (title, symbol, base) = ("All", "list.bullet", "All agents")
            case .custom(let id):
                let view = store.view(id: id)
                title = view?.name ?? "View"
                symbol = view?.iconName ?? AgentViewCriteria.defaultIconName
                base = title
            case .newView: (title, symbol, base) = ("New view", "plus", "New view")
            }
            return CommandBarViewTab(
                id: page.id, title: title, symbol: symbol, isEditable: page.customID != nil,
                shortcutNumber: number, help: number.map { "\(base) (⌘\($0))" } ?? base
            )
        }
    }

    /// The page a strip tab stands for.
    func page(forTabID id: String) -> AgentPage? {
        orderedPages.first { $0.id == id }
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
        guard hasSavedViews, let target = CommandBarViewOrder.numberedTarget(number, in: orderedPages, isNumbered: { $0 != .newView }) else { return false }
        select(target)
        return true
    }

    /// One page forward (positive) or back, clamped at both ends. False at an end.
    @discardableResult
    func step(_ step: Int) -> Bool {
        guard hasSavedViews, let target = CommandBarViewOrder.neighbor(of: activePage, step: step, in: orderedPages) else { return false }
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
        let returnPage = activePage == .newView ? .all : activePage
        editor = AgentViewEditorState(draft: .new(), isNew: true, returnPage: returnPage)
        setActive(.newView)
    }

    func beginEdit(id: UUID, confirmingDelete: Bool = false) {
        guard let view = store.view(id: id) else { return }
        let returnPage = activePage == .newView ? AgentPage.all : activePage
        editor = AgentViewEditorState(draft: AgentViewDraft(view), isNew: false, returnPage: returnPage, isConfirmingDelete: confirmingDelete)
        setActive(.custom(id))
    }

    func cancelEditor() {
        guard let state = editor else { return }
        editor = nil
        setActive(orderedPages.contains(state.returnPage) ? state.returnPage : .all)
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
        if activePage == .custom(id) { setActive(.all) }
    }
}
