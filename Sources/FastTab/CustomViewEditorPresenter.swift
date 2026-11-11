import Foundation
import IndieCommandBar
import Combine

/// The command bar's inline view builder and its delete confirmation.
///
/// Entry points (all in the bar): "Create View" / Return on the New View
/// page, the empty state's "Edit View", and the header pill context menu
/// ("Edit View…", "Delete View"). While `request` is set, the target page
/// (New View, or the edited view's page) shows `CustomViewBarEditor` instead
/// of its content; while `pendingDeleteID` is set, that view's page shows a
/// confirm card. Settings › Views has its own sheet and doesn't use this.
///
/// The draft lives here, not in the view, so key routing (Esc / ⌘Return in
/// `ContentView+CustomViewEditor`) can cancel or save it. It is discarded
/// when the bar hides or the user switches to another page (`syncWith`).
@MainActor
final class CustomViewEditorPresenter: ObservableObject {
    static let shared = CustomViewEditorPresenter(store: .shared, viewStore: .shared)

    enum Request: Equatable {
        case new
        case edit(UUID)
    }

    /// The builder the bar shows; nil = none.
    @Published private(set) var request: Request?
    /// The builder's working copy (meaningful only while `request` is set).
    @Published var draft = CustomViewDraft()
    /// A view awaiting delete confirmation — from the header pill menu (its
    /// page shows a confirm card) or the builder's "Delete View…" (the
    /// builder's footer turns into the confirm row).
    @Published private(set) var pendingDeleteID: UUID?

    private let store: CustomViewStore
    private let viewStore: CommandBarViewStore

    init(store: CustomViewStore, viewStore: CommandBarViewStore) {
        self.store = store
        self.viewStore = viewStore
    }

    /// True while the builder or a delete confirmation owns the bar: key
    /// routing passes typing through, swipes and hover-dismiss are off.
    var holdsBar: Bool { request != nil || pendingDeleteID != nil }

    /// Whether `view`'s page is the one showing the builder.
    func isEditing(on view: CommandBarView) -> Bool {
        switch (request, view) {
        case (.new?, .newView): return true
        case (.edit(let id)?, .custom(let pageID)): return id == pageID
        default: return false
        }
    }

    /// Whether the builder or a confirm card is on `view`'s page.
    func holdsBar(on view: CommandBarView) -> Bool {
        if isEditing(on: view) { return true }
        guard let pendingDeleteID else { return false }
        return view.customID == pendingDeleteID
    }

    // MARK: Open

    /// Opens the builder for a new view on the New View page.
    func presentNew() {
        pendingDeleteID = nil
        if request != .new {
            draft = CustomViewDraft()
            request = .new
        }
        viewStore.selectView(.newView)
    }

    /// Opens the builder for `id` on that view's page.
    func presentEdit(id: UUID) {
        guard let view = store.view(id: id) else { return }
        pendingDeleteID = nil
        if request != .edit(id) {
            draft = CustomViewDraft(view: view)
            request = .edit(id)
        }
        viewStore.selectView(.custom(id))
    }

    /// Closes the builder, discarding the draft. Cancel from New View stays
    /// on the New View page.
    func dismiss() {
        request = nil
        pendingDeleteID = nil
    }

    /// Esc: backs out of a delete confirmation first, then the builder.
    func cancelTopmost() {
        if pendingDeleteID != nil, request != nil {
            pendingDeleteID = nil
        } else {
            dismiss()
        }
    }

    // MARK: Save

    /// Saves a valid draft. A new view is appended and becomes the active
    /// page; an edited one is updated in place. Returns false (and keeps the
    /// builder open) when the draft is invalid.
    @discardableResult
    func save() -> Bool {
        guard let request, let view = draft.savableView else { return false }
        switch request {
        case .new:
            store.add(view)
            dismiss()
            viewStore.selectView(.custom(view.id))
        case .edit(let id):
            guard id == view.id else { return false }
            store.update(view)
            dismiss()
        }
        return true
    }

    // MARK: Delete

    /// Asks to delete `id`, showing the confirmation on its page.
    func requestDelete(id: UUID) {
        guard store.view(id: id) != nil else { return }
        if request != .edit(id) { request = nil }
        pendingDeleteID = id
        viewStore.selectView(.custom(id))
    }

    func cancelDelete() {
        pendingDeleteID = nil
    }

    /// Deletes the pending view; the bar falls back to Recents
    /// (`CommandBarViewStore` follows the store).
    func confirmDelete() {
        guard let id = pendingDeleteID else { return }
        pendingDeleteID = nil
        if request == .edit(id) { request = nil }
        store.delete(id: id)
    }

    // MARK: Bar lifecycle

    /// Called whenever the active page or the bar's visibility changes:
    /// the builder/confirmation belongs to one page and one open of the bar.
    func syncWith(activeView: CommandBarView, isBarVisible: Bool) {
        guard isBarVisible else {
            if holdsBar { dismiss() }
            return
        }
        if request != nil, !isEditing(on: activeView) { request = nil }
        if let pendingDeleteID, activeView.customID != pendingDeleteID { self.pendingDeleteID = nil }
    }
}
