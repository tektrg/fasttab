import SwiftUI
import FastTabSync

/// "View all" from the Read tab's Recent Added shelf: a full screen with its own bottom tab
/// bar. **FastTab List** (phone-saved + shared links), **Bookmarks** (Mac bookmarks),
/// **Read** (finished, 99-100%) and **Trash** (the FastTab List's Trash).
///
/// A finished link appears only under Read (`LinkShelves`), never in the other tabs or on the
/// shelf. Rows come from `RecentAddedProvider`, so dedupe and sources match the shelf.
struct LinkLibraryView: View {
    enum Tab: Hashable { case fastTabList, bookmarks, read, trash }

    @ObservedObject private var recentProvider = RecentAddedProvider.shared
    @ObservedObject private var readingProgress = ReaderReadingProgress.shared
    @ObservedObject private var savedStore = SavedOnIPhoneStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var selection: Tab
    @State private var readerItem: ReaderNavigationItem?
    @State private var toast: String?

    init(initialTab: Tab = .fastTabList) {
        _selection = State(initialValue: initialTab)
    }

    private var split: LinkShelves.Split<RecentAddedItem> {
        RecentAddedProgress(reading: readingProgress, saved: savedStore).split(recentProvider.items)
    }

    var body: some View {
        let split = split
        TabView(selection: $selection) {
            linkTab(
                "FastTab List", items: split.fastTabList,
                emptyIcon: "tray",
                emptyText: "Links you save or share to FastTab show up here until you finish reading them."
            )
            .tabItem { Label("FastTab List", systemImage: "tray.full") }
            .tag(Tab.fastTabList)

            linkTab(
                "Bookmarks", items: split.bookmarks,
                emptyIcon: "bookmark",
                emptyText: "Bookmarks synced from your Mac show up here until you finish reading them."
            )
            .tabItem { Label("Bookmarks", systemImage: "bookmark") }
            .tag(Tab.bookmarks)

            linkTab(
                "Read", items: split.read,
                emptyIcon: "checkmark.circle",
                emptyText: "Links you read to the end (99%+) move here."
            )
            .tabItem { Label("Read", systemImage: "checkmark.circle") }
            .tag(Tab.read)

            FastTabListTrashView()
                .tabItem { Label("Trash", systemImage: "trash") }
                .tag(Tab.trash)
        }
        .dsToast($toast)
        .fullScreenCover(item: $readerItem) { item in
            ReaderView(url: item.url, title: item.title, focusHighlightID: item.focusHighlightID)
        }
    }

    private func linkTab(
        _ title: String, items: [RecentAddedItem], emptyIcon: String, emptyText: String
    ) -> some View {
        NavigationStack {
            Group {
                if items.isEmpty {
                    ContentUnavailableView(
                        "Nothing here yet", systemImage: emptyIcon, description: Text(emptyText)
                    )
                } else {
                    List {
                        ForEach(items) { item in
                            row(item)
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) {
                                        toast = recentProvider.delete(item)
                                    } label: {
                                        Label(deleteTitle(item), systemImage: "trash")
                                    }
                                }
                        }
                        .dsListRow()
                    }
                    .listStyle(.plain)
                    .dsListStyle()
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func row(_ item: RecentAddedItem) -> some View {
        let progress = RecentAddedProgress(reading: readingProgress, saved: savedStore).progress(item)
        return Button {
            LastOpenedStore.shared.recordOpened(url: item.url, title: item.title)
            readerItem = ReaderNavigationItem(url: item.url, title: item.title)
        } label: {
            LinkLibraryRow(
                title: item.title,
                url: item.url,
                domain: item.domain,
                progress: progress,
                badgeText: item.source.badgeText,
                badgeTint: item.source.tintColor,
                badgeIcon: item.source.iconName
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Link(destination: item.url) { Label("Open in Safari", systemImage: "safari") }
            Button {
                UIPasteboard.general.url = item.url
            } label: {
                Label("Copy Link", systemImage: "doc.on.doc")
            }
            Button(role: .destructive) {
                toast = recentProvider.delete(item)
            } label: {
                Label(deleteTitle(item), systemImage: "trash")
            }
        }
    }

    private func deleteTitle(_ item: RecentAddedItem) -> String {
        item.source.isBookmark ? "Delete Bookmark" : "Delete Link"
    }
}
