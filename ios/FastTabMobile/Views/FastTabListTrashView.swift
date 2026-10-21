import SwiftUI
import FastTabSync

/// Trash for the FastTab List: links deleted from the list wait here 30 days
/// (`FastTabListLibrary.trashRetention`) before they are purged for good.
struct FastTabListTrashView: View {
    @ObservedObject private var store = SavedOnIPhoneStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingEmpty = false

    var body: some View {
        NavigationStack {
            Group {
                if store.trashedItems.isEmpty {
                    ContentUnavailableView(
                        "Trash is empty",
                        systemImage: "trash",
                        description: Text("Links you delete from your FastTab List stay here for 30 days.")
                    )
                } else {
                    trashList
                }
            }
            .navigationTitle("Trash")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .destructiveAction) {
                    Button("Empty Trash", role: .destructive) { confirmingEmpty = true }
                        .disabled(store.trashedItems.isEmpty)
                }
            }
            .confirmationDialog(
                "Delete \(store.trashedItems.count) links for good?",
                isPresented: $confirmingEmpty,
                titleVisibility: .visible
            ) {
                Button("Empty Trash", role: .destructive) { withAnimation { store.emptyTrash() } }
            }
        }
    }

    private var trashList: some View {
        List {
            Section {
                ForEach(store.trashedItems) { link in
                    row(link)
                        .swipeActions(edge: .trailing) {
                            Button("Delete Now", role: .destructive) { withAnimation { store.deleteNow(id: link.id) } }
                        }
                        .swipeActions(edge: .leading) {
                            Button("Restore") { withAnimation { store.restore(id: link.id) } }
                                .tint(.green)
                        }
                        .contextMenu {
                            Button("Restore", systemImage: "arrow.uturn.backward") { store.restore(id: link.id) }
                            Button("Delete Now", systemImage: "trash", role: .destructive) { store.deleteNow(id: link.id) }
                        }
                }
            } footer: {
                Text("Items are deleted for good 30 days after you delete them.")
            }
        }
    }

    private func row(_ link: SavedOnIPhoneLink) -> some View {
        let host = URL(string: link.url)?.host() ?? link.url
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(link.title ?? host).lineLimit(2)
                Text(subtitle(host: host, deletedAt: link.deletedAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                withAnimation { store.restore(id: link.id) }
            } label: {
                Image(systemName: "arrow.uturn.backward.circle")
                    .imageScale(.large)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Restore")
        }
    }

    private func subtitle(host: String, deletedAt: Date?) -> String {
        guard let deletedAt else { return host }
        let purgeDate = deletedAt.addingTimeInterval(FastTabListLibrary.trashRetention)
        let days = max(0, Calendar.current.dateComponents([.day], from: Date(), to: purgeDate).day ?? 0)
        return "\(host) · deleted for good in \(days) day\(days == 1 ? "" : "s")"
    }
}
