import Foundation
import SwiftUI
import FastTabSync

/// The **FastTab List** (read-later list; type keeps its older "Saved on iPhone"
/// name). Rules live in `FastTabListLibrary`, disk format in `FastTabListFileStore`;
/// this class publishes them to SwiftUI and debounces writes.
///
/// `items` is live items only, so the Read feed, Shuffle, widgets and search never
/// see Trash; `trashedItems` feeds `FastTabListTrashView`.
///
/// The share extension cannot reach this store, so new saves land as one JSON file
/// each in the app-group `pending_saves` directory and are drained on launch and
/// foreground (which also purges Trash older than 30 days).
@MainActor
public final class SavedOnIPhoneStore: ObservableObject {
    public static let shared = SavedOnIPhoneStore()

    @Published public private(set) var items: [SavedOnIPhoneLink] = []
    @Published public private(set) var trashedItems: [SavedOnIPhoneLink] = []

    private var library: FastTabListLibrary
    private let fileStore: FastTabListFileStore
    private let pendingSavesContainerURL: URL?
    private let now: () -> Date
    private let writeDebounce: Duration
    private var pendingWriteTask: Task<Void, Never>?

    init(
        fileStore: FastTabListFileStore = FastTabListFileStore(),
        pendingSavesContainerURL: URL? = AppGroupContainer.directoryURL,
        now: @escaping () -> Date = Date.init,
        writeDebounce: Duration = .milliseconds(500)
    ) {
        self.fileStore = fileStore
        self.pendingSavesContainerURL = pendingSavesContainerURL
        self.now = now
        self.writeDebounce = writeDebounce
        self.library = FastTabListLibrary(items: fileStore.load())
        publish()
        drainPendingSaves()
    }

    public func item(forURL url: String) -> SavedOnIPhoneLink? {
        library.item(forURL: url)
    }

    /// Ingests share-extension saves and purges expired Trash. Idempotent:
    /// pending files are deleted as they are read.
    public func drainPendingSaves() {
        let drained = pendingSavesContainerURL.map { SavedOnIPhoneFiles.drain(containerURL: $0) } ?? []
        let purged = library.purgeExpiredTrash(now: now())
        guard !drained.isEmpty || purged else { return }
        mutate { library in drained.forEach { library.save($0, now: self.now()) } }
    }

    /// Saves links added inside the app (clipboard, onboarding) the same way as
    /// share saves: same URL is one item, and a trashed one is restored.
    public func add(_ links: [SavedOnIPhoneLink]) {
        guard !links.isEmpty else { return }
        mutate { library in links.forEach { library.save($0, now: self.now()) } }
    }

    /// Delete from the list = move to Trash.
    public func remove(id: String) { mutate { $0.moveToTrash(id: id, now: self.now()) } }
    public func restore(id: String) { mutate { $0.restore(id: id, now: self.now()) } }
    public func deleteNow(id: String) { mutate { $0.deleteNow(id: id) } }
    public func emptyTrash() { mutate { $0.emptyTrash() } }
    public func setRead(id: String, _ isRead: Bool) { mutate { $0.setRead(id: id, isRead, now: self.now()) } }

    /// Called by the reader; ignored for articles that aren't in the list.
    public func recordProgress(url: URL, progress: Double) {
        var updated = library
        guard updated.recordProgress(url: url.absoluteString, progress: progress, now: now()) else { return }
        library = updated
        publish()
        scheduleWrite()
    }

    /// Writes any debounced change now (app going to background).
    public func flushPendingWrite() {
        guard pendingWriteTask != nil else { return }
        pendingWriteTask?.cancel()
        pendingWriteTask = nil
        writeNow()
    }

    private func mutate(_ change: (inout FastTabListLibrary) -> Void) {
        change(&library)
        publish()
        scheduleWrite()
    }

    private func publish() {
        let live = library.liveItems
        let trashed = library.trashedItems
        if live != items { items = live }
        if trashed != trashedItems { trashedItems = trashed }
    }

    private func scheduleWrite() {
        pendingWriteTask?.cancel()
        let delay = writeDebounce
        pendingWriteTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.pendingWriteTask = nil
            self.writeNow()
        }
    }

    private func writeNow() {
        try? fileStore.write(Array(library.itemsByID.values))
    }
}
