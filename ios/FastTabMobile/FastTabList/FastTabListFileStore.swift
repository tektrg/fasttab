import Foundation
import FastTabSync

/// Disk format for the FastTab List: one JSON file in Application Support,
/// replaced atomically on every write.
///
/// Why a JSON file and not GRDB: GRDB is only linked into the Mac app; the iOS
/// target has no SQLite layer, and the list is small (thousands of ~300-byte rows,
/// well under a few MB). An atomic file write cannot leave a half-written list,
/// needs no schema migrations, and phase 2 sync works on whole records anyway.
/// Writes are debounced by `SavedOnIPhoneStore`, not here.
struct FastTabListFileStore {
    /// Pre-file storage (whole array in `UserDefaults.standard`), migrated once.
    static let legacyDefaultsKey = "FastTabMobile.savedOnIPhoneV1"
    static let migrationDoneKey = "FastTabMobile.fastTabListMigratedToFileV1"

    let fileURL: URL
    let defaults: UserDefaults

    static var defaultFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("FastTabList", isDirectory: true)
            .appendingPathComponent("list.json")
    }

    init(fileURL: URL = Self.defaultFileURL, defaults: UserDefaults = .standard) {
        self.fileURL = fileURL
        self.defaults = defaults
    }

    /// Loads the list, first moving any old UserDefaults saves into the file
    /// (ids and dates kept). The marker is set only after the file is written, so a
    /// failed write retries next launch instead of losing the old saves.
    func load() -> [SavedOnIPhoneLink] {
        let fromFile = readFile()
        guard !defaults.bool(forKey: Self.migrationDoneKey) else { return fromFile }

        let legacy = defaults.data(forKey: Self.legacyDefaultsKey)
            .flatMap { try? JSONDecoder().decode([SavedOnIPhoneLink].self, from: $0) } ?? []
        let merged = fromFile + legacy
        if legacy.isEmpty || (try? write(merged)) != nil {
            defaults.set(true, forKey: Self.migrationDoneKey)
            defaults.removeObject(forKey: Self.legacyDefaultsKey)
        }
        return merged
    }

    func write(_ items: [SavedOnIPhoneLink]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(items).write(to: fileURL, options: .atomic)
    }

    private func readFile() -> [SavedOnIPhoneLink] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([SavedOnIPhoneLink].self, from: data)) ?? []
    }
}
