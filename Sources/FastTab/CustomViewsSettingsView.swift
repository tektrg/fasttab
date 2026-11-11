import SwiftUI
import IndieCommandBar

/// Settings › Views: the user's custom views (the swipeable pages after
/// Recent and Stack) — reorder by dragging, edit / create in a sheet that
/// hosts the same builder as the command bar, delete with confirmation.
struct CustomViewsSettingsView: View {
    @ObservedObject private var store = CustomViewStore.shared

    @State private var session: EditorSession?
    @State private var pendingDelete: CustomView?

    /// One open of the editor sheet.
    struct EditorSession: Identifiable {
        let id = UUID()
        var draft: CustomViewDraft
        let isNew: Bool
    }

    var body: some View {
        // No `.fixedSize(vertical:)` on anything here: this page is not in a
        // ScrollView, so its ideal height reaches the split view, which sizes
        // itself to it at a narrow measuring width (~1,900pt) and gets centred
        // in the fixed 420pt window: blank sidebar + blank page. Guarded by
        // SettingsWindowLayoutTests.
        VStack(alignment: .leading, spacing: 10) {
            Text("Your own pages in the command bar, after Recent and Stack: open tabs, bookmarks and history filtered your way. Drag to change the swipe order.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if store.views.isEmpty {
                emptyState
            } else {
                list
            }

            HStack {
                Spacer()
                Button {
                    session = EditorSession(draft: CustomViewDraft(), isNew: true)
                } label: {
                    Label("New View", systemImage: "plus")
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(item: $session) { session in
            CustomViewSettingsEditorSheet(session: session) { saved in
                if session.isNew {
                    store.add(saved)
                } else {
                    store.update(saved)
                }
                self.session = nil
            } onDelete: {
                store.delete(id: session.draft.id)
                self.session = nil
            } onCancel: {
                self.session = nil
            }
        }
        .confirmationDialog(
            "Delete “\(pendingDelete.map { CommandBarView.custom($0.id).displayName(customViews: store.views) } ?? "")”?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { view in
            Button("Delete View", role: .destructive) {
                store.delete(id: view.id)
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { _ in
            Text("The view goes away. Your tabs, bookmarks and history stay as they are.")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "square.stack.3d.up")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("No views yet")
                .font(.headline)
            Text("Create one here, or swipe to “New View” at the end of the command bar.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        List {
            ForEach(store.views) { view in
                row(view)
            }
            .onMove { offsets, destination in
                store.move(fromOffsets: offsets, toOffset: destination)
            }
        }
        .listStyle(.bordered(alternatesRowBackgrounds: false))
    }

    private func row(_ view: CustomView) -> some View {
        HStack(spacing: 10) {
            Image(systemName: CommandBarView.custom(view.id).iconName(customViews: store.views))
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(CommandBarView.custom(view.id).displayName(customViews: store.views))
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Text(view.filterSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 8)
            Button {
                edit(view)
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .help("Edit \(view.name)")
            Button {
                pendingDelete = view
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete \(view.name)")
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { edit(view) }
        .contextMenu {
            Button("Edit View…") { edit(view) }
            Button("Delete View…", role: .destructive) { pendingDelete = view }
        }
    }

    private func edit(_ view: CustomView) {
        session = EditorSession(draft: CustomViewDraft(view: view), isNew: false)
    }
}

/// The builder in a sheet sized to fit the fixed 680×420 Settings window.
private struct CustomViewSettingsEditorSheet: View {
    let isNew: Bool
    let onSave: (CustomView) -> Void
    let onDelete: () -> Void
    let onCancel: () -> Void

    @State private var draft: CustomViewDraft
    @State private var isConfirmingDelete = false

    init(
        session: CustomViewsSettingsView.EditorSession,
        onSave: @escaping (CustomView) -> Void,
        onDelete: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.isNew = session.isNew
        self.onSave = onSave
        self.onDelete = onDelete
        self.onCancel = onCancel
        _draft = State(initialValue: session.draft)
    }

    var body: some View {
        CustomViewEditor(
            draft: $draft,
            isNew: isNew,
            style: .sheet,
            isConfirmingDelete: $isConfirmingDelete,
            onCancel: onCancel,
            onSave: {
                if let view = draft.savableView { onSave(view) }
            },
            onDelete: isNew ? nil : onDelete
        )
        .frame(width: 520, height: 370)
    }
}
