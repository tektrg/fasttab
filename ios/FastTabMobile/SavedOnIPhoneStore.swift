import Foundation
import SwiftUI
import FastTabSync

/// Local-only reading list for links the user kept on this iPhone via the
/// share sheet ("Save to iPhone"). Never uploaded, never synced — the
/// counterpart to the Mac-bound `openOnMac` command path.
///
/// The share extension cannot touch `UserDefaults.standard`, so new saves
/// land as one JSON file each in the shared `pending_saves` directory and
/// are drained into this store on launch and foreground, mirroring the
/// `pending_shares` → `LocalCache` handoff.
@MainActor
public final class SavedOnIPhoneStore: ObservableObject {
    public static let shared = SavedOnIPhoneStore()

    @Published public private(set) var items: [SavedOnIPhoneLink] = []

    private static let defaultsKey = "FastTabMobile.savedOnIPhoneV1"
    private static let maxStoredItems = 100

    private init() {
        loadFromDisk()
        drainPendingSaves()
    }

    public func loadFromDisk() {
        guard let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
              let decoded = try? JSONDecoder().decode([SavedOnIPhoneLink].self, from: data) else {
            self.items = []
            return
        }
        self.items = decoded.sorted { $0.savedAt > $1.savedAt }
    }

    /// Ingests any `pending_saves` files left by the share extension.
    /// Idempotent: files are deleted as they are read.
    public func drainPendingSaves() {
        let drained = SavedOnIPhoneFiles.drain(containerURL: AppGroupContainer.directoryURL)
        guard !drained.isEmpty else { return }
        var merged = items
        for link in drained {
            merged.removeAll { $0.url.lowercased() == link.url.lowercased() }
            merged.append(link)
        }
        merged.sort { $0.savedAt > $1.savedAt }
        items = Array(merged.prefix(Self.maxStoredItems))
        saveToDisk()
    }

    public func remove(id: String) {
        items.removeAll { $0.id == id }
        saveToDisk()
    }

    public func clear() {
        items.removeAll()
        saveToDisk()
    }

    private func saveToDisk() {
        if let encoded = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(encoded, forKey: Self.defaultsKey)
        }
    }
}
