import Combine
import FastTabSync
import Foundation

/// The Mac's copy of the **FastTab List** (read-later list synced with the phone/iPad through
/// `ReaderZone`). Rules live in the shared `FastTabListLibrary`, disk format in the shared
/// `FastTabListFileStore`; this class publishes them to the command bar.
///
/// Local edits (save, Trash, restore) post `fastTabListDidChangeLocally`, which
/// `SyncService` turns into a debounced send. Remote edits arrive through
/// `FastTabListSyncStore` and post nothing (no echo).
@MainActor
final class FastTabListStore: ObservableObject {
    static let shared = FastTabListStore()

    /// Live items only (newest saved first); the command bar never shows Trash.
    @Published private(set) var items: [SavedOnIPhoneLink] = []

    private var library: FastTabListLibrary
    private let fileStore: FastTabListFileStore
    private let now: () -> Date
    private var pendingWriteTask: Task<Void, Never>?

    init(fileStore: FastTabListFileStore = FastTabListFileStore(fileURL: FastTabListStore.defaultFileURL),
         now: @escaping () -> Date = Date.init) {
        self.fileStore = fileStore
        self.now = now
        library = FastTabListLibrary(items: fileStore.load())
        library.purgeExpiredTrash(now: now())
        items = library.liveItems
    }

    /// `~/Library/Application Support/com.trungluong.FastTab/FastTabList/list.json`.
    nonisolated static var defaultFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.trungluong.FastTab", isDirectory: true)
            .appendingPathComponent("FastTabList", isDirectory: true)
            .appendingPathComponent("list.json")
    }

    func item(id: String) -> SavedOnIPhoneLink? { library.item(id: id) }

    /// "Read later": returns false for links that can't be read (non-web URLs).
    @discardableResult
    func readLater(url: String, title: String?) -> Bool {
        guard let link = FastTabListBridge.readLaterLink(url: url, title: title, now: now()) else { return false }
        mutate { $0.save(link, now: self.now()) }
        return true
    }

    /// Reader scroll position for a list item (≥ 90 % also marks it read). Synced like any
    /// local edit; a URL that isn't in the list is ignored.
    func recordReaderProgress(url: String, progress: Double) {
        mutate { $0.recordProgress(url: url, progress: progress, now: self.now()) }
    }

    func moveToTrash(id: String) { mutate { $0.moveToTrash(id: id, now: self.now()) } }
    func restore(id: String) { mutate { $0.restore(id: id, now: self.now()) } }

    /// Writes a debounced change now (app quitting), so the last edit isn't lost.
    func flushPendingWrite() {
        guard let task = pendingWriteTask else { return }
        task.cancel()
        pendingWriteTask = nil
        try? fileStore.write(Array(library.itemsByID.values))
    }

    // MARK: - Private

    private func mutate(_ change: (inout FastTabListLibrary) -> Void) {
        let before = library
        change(&library)
        guard library != before else { return }
        persistAndPublish()
        NotificationCenter.default.post(name: .fastTabListDidChangeLocally, object: nil)
    }

    /// Remote changes: saved and shown, but not announced as local edits.
    private func applySynced(_ change: (inout FastTabListLibrary) -> Void) {
        let before = library
        change(&library)
        guard library != before else { return }
        persistAndPublish()
    }

    private func persistAndPublish() {
        items = library.liveItems
        scheduleWrite()
    }

    /// One write per burst (a first sync applies records one by one).
    private func scheduleWrite() {
        pendingWriteTask?.cancel()
        pendingWriteTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, !Task.isCancelled else { return }
            self.pendingWriteTask = nil
            try? self.fileStore.write(Array(self.library.itemsByID.values))
        }
    }
}

extension Notification.Name {
    /// The user changed the FastTab List on this Mac (SyncService sends it, debounced).
    static let fastTabListDidChangeLocally = Notification.Name("FastTab.fastTabListDidChangeLocally")
}

extension FastTabListStore: FastTabListSyncStore {
    func listItemsForSync() -> [SavedOnIPhoneLink] {
        Array(library.itemsByID.values)
    }

    func applyRemoteListItem(_ item: SavedOnIPhoneLink) -> SavedOnIPhoneLink {
        var merged = item
        applySynced { merged = $0.applyRemote(item) }
        return merged
    }

    func removeRemoteListItem(id: String) {
        applySynced { $0.removeRemote(id: id, now: self.now()) }
    }
}
