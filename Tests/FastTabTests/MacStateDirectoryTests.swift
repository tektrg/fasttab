import Testing
import CloudKit
import Foundation
@testable import FastTabSync

/// The history-free fast path: each Mac lists its live state-zone records in one
/// small directory record, and a phone fetches those records by ID instead of
/// walking the state zone's whole change history.
@Suite("Mac state directory")
struct MacStateDirectoryTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let macA = "AAAA-1111"
    private let macB = "BBBB-2222"

    private func entry(_ id: String, names: [String], seen: Date? = nil, name: String = "Mac") -> MacStateDirectoryEntry {
        MacStateDirectoryEntry(deviceID: id, deviceName: name, lastSeenAt: seen ?? now, recordNames: names)
    }

    // MARK: Entry

    @Test("An entry always lists the Mac's own device record, sorted and without duplicates")
    func entryNormalizesNames() {
        let e = entry(macA, names: ["\(macA)_Chrome_tab_2", "\(macA)_Chrome_tab_1", "\(macA)_Chrome_tab_2"])
        #expect(e.recordNames == [macA, "\(macA)_Chrome_tab_1", "\(macA)_Chrome_tab_2"])
    }

    // MARK: Ownership

    @Test("Every record a Mac publishes in the state zone counts as its own; other devices' do not")
    func ownership() {
        let owned = [
            macA,                                   // SyncedDevice
            "\(macA)_Google Chrome_tab_42",         // SyncedTab (extension)
            "\(macA)_Safari_win1_idx3",             // SyncedTab (AppleScript)
            "\(macA)|Chrome|Default",               // SyncedBookmarkBlob
            "\(macA)|Chrome|history",               // SyncedHistorySlice
            "\(macA)|tabstats",                     // SyncedTabStats
            "\(macA)|favicons",                     // SyncedFavicons
            "tab_order_\(macA)"                     // SyncedTabOrder
        ]
        for name in owned {
            #expect(MacStateDirectory.isOwnedStateRecordName(name, deviceID: macA), "\(name)")
        }
        for name in [macB, "\(macB)_Chrome_tab_1", "tab_order_\(macB)", "\(macA)extra", "x\(macA)"] {
            #expect(!MacStateDirectory.isOwnedStateRecordName(name, deviceID: macA), "\(name)")
        }
    }

    // MARK: Merge (one shared record, several Macs)

    @Test("Merging replaces only this Mac's entry and keeps every other Mac's")
    func mergeKeepsOtherMacs() {
        let server = MacStateDirectory(entries: [entry(macA, names: ["old"]), entry(macB, names: ["\(macB)_x"])])
        let merged = server.merging(entry(macA, names: ["\(macA)_new"]), now: now)
        #expect(merged.entry(for: macA)?.recordNames == [macA, "\(macA)_new"])
        #expect(merged.entry(for: macB) == server.entry(for: macB))
        #expect(merged.entries.map(\.deviceID) == [macA, macB])
    }

    @Test("Merging drops other Macs not seen within the retention window")
    func mergePrunesLongGoneMacs() {
        let longGone = entry(macB, names: [], seen: now.addingTimeInterval(-(MacStateDirectory.retention + 1)))
        let merged = MacStateDirectory(entries: [longGone]).merging(entry(macA, names: []), now: now)
        #expect(merged.entries.map(\.deviceID) == [macA])
    }

    // MARK: Encoding

    @Test("Directory round-trips through a CloudKit record")
    func recordRoundTrip() throws {
        let directory = MacStateDirectory(entries: [entry(macA, names: ["\(macA)|favicons"], name: "Studio")])
        let record = try #require(directory.applying(to: MacStateDirectory.newRecord()))
        #expect(record.recordID == MacStateDirectory.recordID)
        #expect(record.recordID.zoneID.zoneName == MacStateDirectory.zoneName)
        #expect(MacStateDirectory(from: record) == directory)
    }

    @Test("A record of another type, or with no payload, is not a directory")
    func rejectsForeignRecords() {
        let foreign = CKRecord(recordType: "SyncedDevice", recordID: MacStateDirectory.recordID)
        #expect(MacStateDirectory(from: foreign) == nil)
        #expect(MacStateDirectory(from: MacStateDirectory.newRecord()) == nil)
    }

    @Test("One unreadable entry drops only itself, and unknown future fields are ignored")
    func lossyDecode() throws {
        let json = """
        {"version": 9, "futureField": true, "entries": [
          {"deviceID": "\(macA)", "deviceName": "A", "lastSeenAt": 0, "recordNames": ["\(macA)"], "extra": 1},
          {"deviceName": "no id"}
        ]}
        """
        let directory = try #require(MacStateDirectory.decodePayload(Data(json.utf8)))
        #expect(directory.entries.map(\.deviceID) == [macA])
        #expect(MacStateDirectory.decodePayload(Data("not json".utf8)) == nil)
    }

    // MARK: Write policy (CloudKit write volume)

    @Test("Writes on first publish and on a changed record set; not on an unchanged one")
    func writeOnlyOnChange() {
        let published = entry(macA, names: ["\(macA)_t1"], seen: now.addingTimeInterval(-60))
        #expect(MacStateDirectory.shouldWrite(published: nil, desired: published, now: now))
        #expect(!MacStateDirectory.shouldWrite(published: published, desired: entry(macA, names: ["\(macA)_t1"]), now: now))
        #expect(MacStateDirectory.shouldWrite(published: published, desired: entry(macA, names: ["\(macA)_t2"]), now: now))
        #expect(MacStateDirectory.shouldWrite(published: published, desired: entry(macA, names: ["\(macA)_t1"], name: "Renamed"), now: now))
    }

    @Test("An unchanged entry is still refreshed after the liveness interval")
    func livenessRefresh() {
        let interval = MacStateDirectory.livenessRefreshInterval
        let fresh = entry(macA, names: [], seen: now.addingTimeInterval(-(interval - 1)))
        let stale = entry(macA, names: [], seen: now.addingTimeInterval(-interval))
        #expect(!MacStateDirectory.shouldWrite(published: fresh, desired: entry(macA, names: []), now: now))
        #expect(MacStateDirectory.shouldWrite(published: stale, desired: entry(macA, names: []), now: now))
    }

    @Test("Writes are spaced out and back off after a failure")
    func writeDelay() {
        let debounce = MacStateDirectory.writeDebounce
        let spacing = MacStateDirectory.minimumWriteSpacing
        #expect(MacStateDirectory.writeDelay(lastWriteAt: nil, retryAfter: nil, now: now) == debounce)
        #expect(MacStateDirectory.writeDelay(lastWriteAt: now.addingTimeInterval(-10), retryAfter: nil, now: now) == spacing - 10)
        #expect(MacStateDirectory.writeDelay(lastWriteAt: now.addingTimeInterval(-spacing * 3), retryAfter: nil, now: now) == debounce)
        #expect(MacStateDirectory.writeDelay(lastWriteAt: nil, retryAfter: now.addingTimeInterval(300), now: now) == 300)
        #expect(MacStateDirectory.retryBackoff(afterFailures: 1) == spacing)
        #expect(MacStateDirectory.retryBackoff(afterFailures: 3) == spacing * 4)
        #expect(MacStateDirectory.retryBackoff(afterFailures: 50) == MacStateDirectory.maxRetryBackoff)
    }
}

/// The Mac's list of its own records that exist on the server, kept from save /
/// delete acknowledgements and re-based on the state-zone mirror.
@Suite("Owned state-record ledger")
struct OwnedStateRecordLedgerTests {
    @Test("Acknowledged saves add names, acknowledged deletes remove them")
    func acks() {
        var ledger = OwnedStateRecordLedger()
        ledger.noteSaved(["a", "b"])
        ledger.noteDeleted(["a"])
        #expect(ledger.recordNames == ["b"])
    }

    @Test("A mirror resync replaces the names, keeping acks that landed while it ran")
    func resyncKeepsConcurrentAcks() {
        var ledger = OwnedStateRecordLedger()
        ledger.noteSaved(["stale", "kept"])
        ledger.beginResync()
        ledger.noteSaved(["savedMeanwhile"])
        ledger.noteDeleted(["deletedMeanwhile"])
        ledger.finishResync(serverRecordNames: ["kept", "deletedMeanwhile", "onlyOnServer"])
        #expect(ledger.recordNames == ["kept", "savedMeanwhile", "onlyOnServer"])
    }

    @Test("A save after a delete during a resync wins, and the reverse")
    func lastAckWinsDuringResync() {
        var ledger = OwnedStateRecordLedger()
        ledger.beginResync()
        ledger.noteDeleted(["x"])
        ledger.noteSaved(["x"])
        ledger.noteSaved(["y"])
        ledger.noteDeleted(["y"])
        ledger.finishResync(serverRecordNames: ["y"])
        #expect(ledger.recordNames == ["x"])
    }

    @Test("Finishing without a begun resync, or after a cancel, changes nothing")
    func finishWithoutBegin() {
        var ledger = OwnedStateRecordLedger()
        ledger.noteSaved(["a"])
        ledger.finishResync(serverRecordNames: [])
        #expect(ledger.recordNames == ["a"])
        ledger.beginResync()
        ledger.cancelResync()
        ledger.finishResync(serverRecordNames: [])
        #expect(ledger.recordNames == ["a"])
    }

    @Test("Persists the names only")
    func codable() throws {
        var ledger = OwnedStateRecordLedger()
        ledger.noteSaved(["a"])
        ledger.beginResync()
        let decoded = try JSONDecoder().decode(OwnedStateRecordLedger.self, from: JSONEncoder().encode(ledger))
        #expect(decoded.recordNames == ["a"])
        #expect(decoded == OwnedStateRecordLedger(recordNames: ["a"]))
    }
}

/// Phone side: what to fetch by ID, and which of the fetched records may be
/// applied without fighting the history-based sync.
@Suite("Direct snapshot fetch and precedence")
struct DirectSnapshotTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let macA = "AAAA-1111"
    private let macB = "BBBB-2222"

    private var directory: MacStateDirectory {
        MacStateDirectory(entries: [
            MacStateDirectoryEntry(deviceID: macA, deviceName: "A", lastSeenAt: t0, recordNames: ["\(macA)_t1", "\(macA)_t2"]),
            MacStateDirectoryEntry(deviceID: macB, deviceName: "B", lastSeenAt: t0, recordNames: ["\(macB)_t1"])
        ])
    }

    @Test("A full snapshot fetches every listed record")
    func fullFetch() {
        let names = MacDirectoryFetchPlan.recordNames(in: directory, alreadyFetched: ["\(macA)_t1"], full: true)
        #expect(Set(names) == [macA, "\(macA)_t1", "\(macA)_t2", macB, "\(macB)_t1"])
    }

    @Test("A light check fetches only new records plus every Mac's device record (its 'last seen')")
    func lightFetch() {
        let already: Set<String> = [macA, "\(macA)_t1", "\(macA)_t2", macB]
        let names = MacDirectoryFetchPlan.recordNames(in: directory, alreadyFetched: already, full: false)
        #expect(Set(names) == [macA, macB, "\(macB)_t1"])
    }

    @Test("Fetches are split into CloudKit-sized batches")
    func batching() {
        let names = (0..<7).map { "n\($0)" }
        #expect(MacDirectoryFetchPlan.batches(names, size: 3) == [["n0", "n1", "n2"], ["n3", "n4", "n5"], ["n6"]])
        #expect(MacDirectoryFetchPlan.batches([], size: 3).isEmpty)
    }

    @Test("A record nobody has applied yet is admitted")
    func admitsUnknown() {
        let precedence = DirectSnapshotPrecedence()
        #expect(precedence.admitsDirect(recordName: "r", modifiedAt: t0))
        #expect(precedence.admitsDirect(recordName: "r", modifiedAt: nil))
    }

    @Test("A record the history sync deleted is never resurrected by a direct snapshot")
    func historyDeleteWins() {
        var precedence = DirectSnapshotPrecedence()
        precedence.noteHistoryApplied(modified: [("r", t0)], deleted: [])
        precedence.noteHistoryApplied(modified: [], deleted: ["r"])
        // The direct fetch was in flight across the delete: its copy is newer than anything applied, still refused.
        #expect(!precedence.admitsDirect(recordName: "r", modifiedAt: t0.addingTimeInterval(60)))
    }

    @Test("Once the history sync sees the record again, direct snapshots may update it")
    func historyRecreateClearsTombstone() {
        var precedence = DirectSnapshotPrecedence()
        precedence.noteHistoryApplied(modified: [], deleted: ["r"])
        precedence.noteHistoryApplied(modified: [("r", t0)], deleted: [])
        #expect(precedence.admitsDirect(recordName: "r", modifiedAt: t0.addingTimeInterval(1)))
    }

    @Test("A direct copy older than (or the same as) what is shown is skipped; a newer one is applied")
    func olderDirectCopySkipped() {
        var precedence = DirectSnapshotPrecedence()
        precedence.noteHistoryApplied(modified: [("r", t0)], deleted: [])
        #expect(!precedence.admitsDirect(recordName: "r", modifiedAt: t0.addingTimeInterval(-1)))
        #expect(!precedence.admitsDirect(recordName: "r", modifiedAt: t0))
        #expect(!precedence.admitsDirect(recordName: "r", modifiedAt: nil))
        #expect(precedence.admitsDirect(recordName: "r", modifiedAt: t0.addingTimeInterval(1)))
    }

    @Test("Direct applies count too: a later, older direct copy cannot roll it back")
    func directAppliesTracked() {
        var precedence = DirectSnapshotPrecedence()
        precedence.noteDirectApplied(recordName: "r", modifiedAt: t0)
        #expect(!precedence.admitsDirect(recordName: "r", modifiedAt: t0.addingTimeInterval(-5)))
    }

    @Test("History is the authority: it may apply an older copy, which then becomes the bar")
    func historyAlwaysSetsTheBar() {
        var precedence = DirectSnapshotPrecedence()
        precedence.noteDirectApplied(recordName: "r", modifiedAt: t0)
        precedence.noteHistoryApplied(modified: [("r", t0.addingTimeInterval(-30))], deleted: [])
        #expect(precedence.admitsDirect(recordName: "r", modifiedAt: t0))
    }

    @Test("Reset forgets tombstones (new iCloud account)")
    func reset() {
        var precedence = DirectSnapshotPrecedence()
        precedence.noteHistoryApplied(modified: [], deleted: ["r"])
        precedence.reset()
        #expect(precedence.admitsDirect(recordName: "r", modifiedAt: t0))
    }
}
