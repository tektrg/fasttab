import Testing
import Foundation
@testable import FastTabSync

@Suite("SyncedFaviconStore (phone-side disk store)")
struct SyncedFaviconStoreTests {
    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("favicon-store-\(UUID().uuidString)", isDirectory: true)
    }

    private func favicons(_ device: String, _ icons: [String: UInt8], at seconds: TimeInterval) -> SyncedFavicons {
        SyncedFavicons(
            deviceID: device,
            icons: icons.mapValues { Data([$0]) },
            updatedAt: Date(timeIntervalSince1970: seconds)
        )
    }

    @Test("Stores icons, survives a restart, and finds www./bare variants")
    func persistsAcrossInstances() {
        let dir = tempDir()
        let first = SyncedFaviconStore(directory: dir)
        first.apply(favicons("mac-1", ["github.com": 1], at: 100))
        #expect(first.iconData(forHost: "github.com") == Data([1]))

        let second = SyncedFaviconStore(directory: dir)
        #expect(second.iconData(forHost: "www.github.com") == Data([1]))
        #expect(second.iconData(forHost: "missing.com") == nil)
    }

    @Test("A stale snapshot for the same Mac never replaces a newer one")
    func olderSnapshotIgnored() {
        let store = SyncedFaviconStore(directory: tempDir())
        store.apply(favicons("mac-1", ["a.com": 2], at: 200))
        store.apply(favicons("mac-1", ["a.com": 1], at: 100))
        #expect(store.iconData(forHost: "a.com") == Data([2]))
        store.apply(favicons("mac-1", ["a.com": 3], at: 300))
        #expect(store.iconData(forHost: "a.com") == Data([3]))
    }

    @Test("Across Macs the most recently updated snapshot wins a shared host")
    func newestMacWins() {
        let store = SyncedFaviconStore(directory: tempDir())
        store.apply(favicons("mac-1", ["a.com": 1, "only1.com": 5], at: 100))
        store.apply(favicons("mac-2", ["a.com": 2], at: 200))
        #expect(store.iconData(forHost: "a.com") == Data([2]))
        #expect(store.iconData(forHost: "only1.com") == Data([5]))
    }

    @Test("Reports a change only when the visible icon set changed")
    func changeReporting() {
        let store = SyncedFaviconStore(directory: tempDir())
        #expect(store.apply(favicons("mac-1", ["a.com": 1], at: 100)))
        #expect(!store.apply(favicons("mac-1", ["a.com": 1], at: 150)))   // same icons, newer stamp
        #expect(!store.apply(favicons("mac-1", ["a.com": 9], at: 50)))    // stale
        #expect(store.apply(favicons("mac-1", ["a.com": 2], at: 200)))
        #expect(!store.remove(recordName: "some-tab-record"))             // a closed tab's deletion
        #expect(store.remove(recordName: SyncedFavicons.recordName(deviceID: "mac-1")))
    }

    @Test("Removing a deleted record drops its icons, in memory and on disk")
    func removal() {
        let dir = tempDir()
        let store = SyncedFaviconStore(directory: dir)
        store.apply(favicons("mac-1", ["a.com": 1], at: 100))
        store.remove(recordName: SyncedFavicons.recordName(deviceID: "mac-1"))
        #expect(store.iconData(forHost: "a.com") == nil)
        #expect(SyncedFaviconStore(directory: dir).iconData(forHost: "a.com") == nil)
    }

    @Test("A corrupt file is skipped (and cleared) without crashing the rest")
    func corruptFile() throws {
        let dir = tempDir()
        let store = SyncedFaviconStore(directory: dir)
        store.apply(favicons("mac-1", ["good.com": 1], at: 100))
        try Data("garbage".utf8).write(to: dir.appendingPathComponent("junk.favicons"))

        let reloaded = SyncedFaviconStore(directory: dir)
        #expect(reloaded.iconData(forHost: "good.com") == Data([1]))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("junk.favicons").path))
    }

    @Test("Hostile host and device strings never reach a file name or a path")
    func hostileStrings() throws {
        let dir = tempDir()
        let store = SyncedFaviconStore(directory: dir)
        let sentinel = "$(echo injected)" // lowercase: hosts are looked up lowercased
        let traversal = "../../escape"
        store.apply(SyncedFavicons(
            deviceID: traversal + sentinel,
            icons: [sentinel: Data([1]), traversal: Data([2])]
        ))
        #expect(store.iconData(forHost: sentinel) == Data([1]))

        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(!names.isEmpty)
        for name in names {
            #expect(!name.lowercased().contains("injected"))
            #expect(!name.contains("/") && !name.contains(".."))
        }
        // Nothing was written outside the store directory.
        let parent = dir.deletingLastPathComponent().deletingLastPathComponent()
        #expect(!FileManager.default.fileExists(atPath: parent.appendingPathComponent("escape").path))
    }

    @Test("An unwritable directory degrades to memory-only instead of crashing")
    func unwritableDirectory() {
        let store = SyncedFaviconStore(directory: URL(fileURLWithPath: "/dev/null/favicons"))
        store.apply(favicons("mac-1", ["a.com": 1], at: 100))
        #expect(store.iconData(forHost: "a.com") == Data([1]))
    }
}
