import SwiftUI
import AppKit

private let kEscapeKeyCode: UInt16 = 53
private let kEnterKeyCode: UInt16 = 36
private let kKeypadEnterKeyCode: UInt16 = 76

/// How the bar's local key monitor should treat a key while the view builder
/// (or a delete confirmation) is on the active page.
enum CustomViewEditorKeyRoute {
    /// The builder isn't showing — route as usual.
    case notInvolved
    /// Handled here; swallow the event.
    case consume
    /// Belongs to the focused field (typing, arrows, Return, Tab, ⌘A…):
    /// deliver it untouched, skipping the bar's own bindings.
    case passThrough
}

extension ContentView {
    /// Called first for every keyDown while the bar is visible
    /// (`setupLocalMonitor`). Esc closes the builder (or backs out of a
    /// delete confirmation) — never the whole bar; ⌘Return saves.
    func routeCustomViewEditorKey(_ event: NSEvent, modifiers: NSEvent.ModifierFlags) -> CustomViewEditorKeyRoute {
        let presenter = env.customViewEditor
        guard presenter.holdsBar(on: viewStore.activeView) else { return .notInvolved }

        if event.keyCode == kEscapeKeyCode, modifiers.isEmpty {
            presenter.cancelTopmost()
            return .consume
        }
        if presenter.isEditing(on: viewStore.activeView) {
            let isReturn = event.keyCode == kEnterKeyCode || event.keyCode == kKeypadEnterKeyCode
            if isReturn, modifiers == [.command] {
                if presenter.pendingDeleteID == nil, !presenter.save() { NSSound.beep() }
                return .consume
            }
            return .passThrough
        }
        // Confirm card over a view's rows: plain keys must not drive the
        // list underneath; ⌘ shortcuts (menus) still work.
        return modifiers.contains(.command) ? .passThrough : .consume
    }

    /// The builder / confirm card is on the active page: scroll events are
    /// the form's (no page swipes) and focus must not jump to the search field.
    var customViewEditorHoldsBar: Bool {
        env.customViewEditor.holdsBar(on: viewStore.activeView)
    }

    /// Drops the builder / confirmation when the bar hides or the page
    /// changes (see `CustomViewEditorPresenter.syncWith`).
    func syncCustomViewEditor() {
        env.customViewEditor.syncWith(activeView: viewStore.activeView, isBarVisible: appState.isVisible)
    }
}

/// Shows the inline builder in place of `page`'s content while the presenter
/// targets that page, and the delete confirm card over a custom view's rows.
/// Observes the presenter itself so `ContentView` doesn't have to.
struct CustomViewEditorSlot<Content: View>: View {
    let page: CommandBarView
    @ObservedObject var presenter: CustomViewEditorPresenter
    @ViewBuilder let content: () -> Content

    @ObservedObject private var store = CustomViewStore.shared

    var body: some View {
        if presenter.isEditing(on: page) {
            CustomViewBarEditor(presenter: presenter)
                .transition(.opacity)
        } else {
            content()
                .overlay {
                    if let id = page.customID, presenter.pendingDeleteID == id {
                        CustomViewDeleteConfirmCard(
                            name: page.displayName(customViews: store.views),
                            onCancel: { presenter.cancelDelete() },
                            onDelete: { presenter.confirmDelete() }
                        )
                        .transition(.opacity)
                    }
                }
        }
    }
}

/// The builder bound to the presenter's draft (command bar host).
private struct CustomViewBarEditor: View {
    @ObservedObject var presenter: CustomViewEditorPresenter

    private var editingID: UUID? {
        if case .edit(let id)? = presenter.request { return id }
        return nil
    }

    var body: some View {
        let editingID = self.editingID
        CustomViewEditor(
            draft: $presenter.draft,
            isNew: editingID == nil,
            style: .bar,
            isConfirmingDelete: Binding(
                get: { editingID != nil && presenter.pendingDeleteID == editingID },
                set: { confirming in
                    if confirming, let editingID {
                        presenter.requestDelete(id: editingID)
                    } else {
                        presenter.cancelDelete()
                    }
                }
            ),
            onCancel: { presenter.dismiss() },
            onSave: { if !presenter.save() { NSSound.beep() } },
            onDelete: editingID == nil ? nil : { presenter.confirmDelete() }
        )
        .id(editingID?.uuidString ?? "new")
    }
}

/// "Delete View" from the header pill menu: confirm over the view's page
/// (an alert would anchor to the screen-sized canvas window).
private struct CustomViewDeleteConfirmCard: View {
    let name: String
    let onCancel: () -> Void
    let onDelete: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.18)
                .contentShape(Rectangle())
                .onTapGesture(perform: onCancel)
            VStack(spacing: 8) {
                Image(systemName: "trash")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Text("Delete “\(name)”?")
                    .font(.headline)
                    .multilineTextAlignment(.center)
                Text("The view goes away. Your tabs, bookmarks and history stay as they are.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("Cancel", action: onCancel)
                        .keyboardShortcut(.cancelAction)
                    Button("Delete View", role: .destructive, action: onDelete)
                }
                .controlSize(.small)
                .padding(.top, 4)
            }
            .padding(16)
            .frame(maxWidth: 300)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.regularMaterial)
            )
            .padding(16)
        }
    }
}
