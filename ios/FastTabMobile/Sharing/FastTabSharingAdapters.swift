import FastTabSync
import Foundation
import IndieAccount
import IndieLibKit
import IndieShareSync

// Fast Tab's three sharing seams (IndieShareSync's `LibraryWriter`, `ShareContentProvider`,
// `ReceivedShareMaterializer`) and the one call that wires them into a coordinator. Fast Tab
// on iPhone keeps its tabs and bookmarks in CloudKit records, not in the L1 library, so a
// tab is copied into the library as a link item when it is shared.

/// The library as sharing sees it, writing at once.
///
/// Not ready to ship as is: Fast Tab has no library lifecycle yet. The library file would sit
/// in the App Group (the share extension saves too), so writes must stop and wait while the
/// app is in the background (Parklet's `LibraryLifecycle`, file locks / `0xdead10cc`).
@MainActor
final class FastTabLibraryWriter: LibraryWriter {
    let database: LibraryDatabase
    let store: LibraryStore

    init(database: LibraryDatabase) {
        self.database = database
        self.store = LibraryStore(database: database)
    }

    @discardableResult
    func perform<Value: Sendable>(_ write: @Sendable (LibraryStore) async throws -> Value) async throws -> Value {
        try await write(store)
    }

    @discardableResult
    func perform<Prepared: Sendable, Value: Sendable>(
        preparing preparation: () async throws -> Prepared,
        _ write: @Sendable (LibraryStore, Prepared) async throws -> Value
    ) async throws -> Value {
        try await write(store, try await preparation())
    }

    /// A tab from the Mac, as the link item a share is made of (one URL = one item).
    func saveForSharing(_ tab: SyncedTab) async throws -> Item {
        try await saveLinkForSharing(url: tab.url, title: tab.title)
    }

    /// A bookmark, as the link item a share is made of.
    func saveForSharing(_ bookmark: SyncedBookmarkItem) async throws -> Item {
        try await saveLinkForSharing(url: bookmark.url, title: bookmark.title)
    }

    private func saveLinkForSharing(url: String, title: String) async throws -> Item {
        try await perform { try await $0.saveLink(url: url, title: title, source: .fastTabShared).item }
    }
}

/// Shares a link item as a `link` snapshot: its title and URL, and a body that shows both
/// (what an app that does not know links displays).
@MainActor
struct FastTabLinkShareContentProvider: ShareContentProvider {
    let store: LibraryStore

    func shareContent(of itemID: ItemID) async throws -> NoteShareContent {
        guard let item = try await store.item(id: itemID) else { throw SharedNotesError.noteNotFound }
        let url = item.url ?? ""
        let body = [item.title, url].filter { !$0.isEmpty }.joined(separator: "\n")
        return NoteShareContent(
            noteID: itemID.uuid, kind: .link, title: item.title.isEmpty ? nil : item.title, body: body,
            url: item.url, createdAt: item.createdAt, images: [])
    }
}

/// Everything Fast Tab needs for sharing, built once from the signed-in session.
@MainActor
struct FastTabSharing {
    /// Tell it `accountChanged()` whenever the signed-in person changes.
    let deviceProvider: AccountShareDeviceProvider
    let coordinator: SharedNotesCoordinator

    init(accountSession: AccountSession, library: FastTabLibraryWriter, userDefaults: UserDefaults = .standard) {
        let configuration = IndieShareSyncConfiguration.fastTab
        deviceProvider = AccountShareDeviceProvider(
            accountSession: accountSession, configuration: configuration, userDefaults: userDefaults)
        coordinator = SharedNotesCoordinator(
            apiClient: accountSession.apiClient,
            appSlug: accountSession.appSlug,
            deviceIdentity: deviceProvider,
            library: library,
            contentProvider: FastTabLinkShareContentProvider(store: library.store),
            materializer: LibraryReceivedShareMaterializer.storingPhotosAsSent(
                library: library, database: library.database, source: .fastTabReceived),
            outgoingFiles: .inLibrary(library.database),
            configuration: configuration,
            userDefaults: userDefaults)
    }

    /// The signed-in person changed (sign-in, sign-out, launch restore): another account's
    /// received links leave at once. The app then calls `coordinator.refreshAll()` once the
    /// device is registered, and on every foreground.
    func accountChanged(signedInUserID: UUID?) async {
        deviceProvider.accountChanged()
        if let signedInUserID { await coordinator.receivedNotesSync.accountSignedIn(signedInUserID) }
    }
}
