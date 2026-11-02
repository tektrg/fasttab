import SwiftUI
import FastTabSync

/// "View all" from the Read tab's Recent Added shelf: a full screen with its own bottom tab
/// bar. **FastTab List** (phone-saved + shared links), **Bookmarks** (Mac bookmarks),
/// **Read Again** (links the user marked to reread), **Read** (finished, 99-100%) and
/// **Trash** (the FastTab List's Trash).
///
/// A finished link appears only under Read, a Read Again link only under Read Again
/// (`LinkShelves`), never in the other tabs or on the shelf. Rows come from
/// `RecentAddedProvider`, so dedupe and sources match the shelf.
struct LinkLibraryView: View {
    enum Tab: Hashable { case fastTabList, bookmarks, readAgain, read, trash }

    @ObservedObject private var recentProvider = RecentAddedProvider.shared
    @ObservedObject private var readingProgress = ReaderReadingProgress.shared
    @ObservedObject private var savedStore = SavedOnIPhoneStore.shared
    @ObservedObject private var readCounts = ReaderReadCounts.shared
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
                "Read Again", items: split.readAgain,
                emptyIcon: ReadAgainLabel.markIcon,
                emptyText: "Links you mark Read Again stay here until you remove them. They also come up in Shuffle and Emerging."
            )
            .tabItem { Label("Read Again", systemImage: ReadAgainLabel.markIcon) }
            .tag(Tab.readAgain)

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
        .readerPresentation(item: $readerItem) { item in
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
                                .swipeActions(edge: .leading) {
                                    readAgainButton(item)
                                }
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) {
                                        toast = delete(item)
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
        let readCount = LinkReadState(saved: savedStore, counts: readCounts).readCount(item.url)
        return Button {
            LastOpenedStore.shared.recordOpened(url: item.url, title: item.title)
            readerItem = ReaderNavigationItem(url: item.url, title: item.title)
        } label: {
            LinkLibraryRow(
                title: item.title,
                url: item.url,
                domain: item.domain,
                progress: progress,
                readCount: readCount,
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
            readAgainButton(item)
            Button(role: .destructive) {
                toast = delete(item)
            } label: {
                Label(deleteTitle(item), systemImage: "trash")
            }
        }
    }

    /// "Read Again" / "Remove from Read Again" (swipe and long-press).
    private func readAgainButton(_ item: RecentAddedItem) -> some View {
        let isReadAgain = savedStore.isReadAgain(item.url)
        return Button {
            toast = LinkReadState(saved: savedStore, counts: readCounts).toggleReadAgain(url: item.url, title: item.title)
        } label: {
            Label(ReadAgainLabel.title(isReadAgain: isReadAgain), systemImage: ReadAgainLabel.icon(isReadAgain: isReadAgain))
        }
        .tint(DS.Tint.action)
    }

    /// A Read Again row is a list item even when the row came in as a share or bookmark:
    /// deleting it sends that item to Trash (restoring brings the flag back).
    private func delete(_ item: RecentAddedItem) -> String {
        if item.source.listItemID == nil, let listItem = savedStore.liveItem(for: item.url), listItem.isReadAgain {
            savedStore.remove(id: listItem.id)
            return "Moved to Trash"
        }
        return recentProvider.delete(item)
    }

    private func deleteTitle(_ item: RecentAddedItem) -> String {
        if savedStore.isReadAgain(item.url) { return "Delete Link" }
        return item.source.isBookmark ? "Delete Bookmark" : "Delete Link"
    }
}
