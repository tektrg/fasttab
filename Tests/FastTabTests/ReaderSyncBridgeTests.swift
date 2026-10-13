import CloudKit
import Foundation
import IndieComments
import Testing
@testable import FastTabSync
@testable import FastTab

/// Two devices, each a bridge over its own temp folder, passing records by hand the way
/// CloudKit would.
@MainActor
@Suite("Reader sync bridge (highlights + comment threads)")
struct ReaderSyncBridgeTests {
    final class MemoryHighlights: ReaderHighlightSyncStore {
        var byID: [String: SyncedReaderHighlight] = [:]
        func syncedHighlights() -> [SyncedReaderHighlight] { byID.values.sorted { $0.id < $1.id } }
        func applyRemote(_ highlight: SyncedReaderHighlight) { byID[highlight.id] = highlight }
        func removeRemote(id: String) { byID[id] = nil }
    }

    struct Device {
        let highlights = MemoryHighlights()
        let bridge: ReaderSyncBridge
        let comments: CommentStore

        @MainActor init() {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("reader-sync-\(UUID().uuidString)")
            comments = CommentStore(log: CommentLog(directory: dir.appendingPathComponent("comments")))
            bridge = ReaderSyncBridge(
                ledgerURL: dir.appendingPathComponent("ledger.json"), comments: comments, highlights: highlights)
        }

        /// Sends everything pending and reports it confirmed, as CloudKit would.
        @MainActor func send() async -> (saves: [CKRecord], deletes: [CKRecord.ID]) {
            let pending = await bridge.pendingChanges()
            pending.saves.forEach(bridge.didSave)
            pending.deletes.forEach(bridge.didDelete)
            return pending
        }
    }

    let me = CommentAuthor(kind: .human, id: "me")
    let agent = CommentAuthor(kind: .agent, id: "claude")

    func highlight(_ id: String, tags: String = "") -> SyncedReaderHighlight {
        SyncedReaderHighlight(id: id, urlKey: "https://a.com/x", payload: Data(#"{"id":"\#(id)","tags":"\#(tags)"}"#.utf8))
    }

    @Test func highlightsAndCommentsReachTheOtherDeviceOnce() async throws {
        let phone = Device(), mac = Device()
        phone.highlights.byID["h1"] = highlight("h1")
        let docId = ReaderCommentDocID.forArticle(urlKey: "https://a.com/x")
        let thread = try await phone.comments.openThread(
            docId: docId, author: me, anchor: TextAnchor(from: 0, to: 4, quote: "beta"), text: "why?")

        let sent = await phone.send()
        #expect(sent.saves.count == 2)
        #expect(await phone.bridge.pendingChanges().saves.isEmpty, "confirmed records are not sent again")

        await mac.bridge.absorb(sent.saves)
        #expect(mac.highlights.byID["h1"] == highlight("h1"))
        #expect(try await mac.comments.threads(docId: docId, text: "").first?.messages.map(\.text) == ["why?"])
        #expect(await mac.bridge.pendingChanges().saves.isEmpty, "received records are not echoed back")

        // An agent replies on the Mac; the reply alone goes back to the phone.
        try await mac.comments.reply(docId: docId, threadId: thread, author: agent, text: "because")
        let reply = await mac.send()
        #expect(reply.saves.map(\.recordType) == [SyncedCommentEvent.recordType])
        await phone.bridge.absorb(reply.saves)
        #expect(try await phone.comments.threads(docId: docId, text: "").first?.messages.count == 2)
    }

    @Test func editsGoOutAndDeletesPropagate() async throws {
        let phone = Device(), mac = Device()
        phone.highlights.byID["h1"] = highlight("h1")
        await mac.bridge.absorb(await phone.send().saves)

        phone.highlights.byID["h1"] = highlight("h1", tags: "work")
        let edit = await phone.send()
        #expect(edit.saves.count == 1)
        await mac.bridge.absorb(edit.saves)
        #expect(mac.highlights.byID["h1"] == highlight("h1", tags: "work"))

        phone.highlights.byID["h1"] = nil
        let removal = await phone.send()
        #expect(removal.deletes.map(\.recordName) == ["hl|h1"])
        mac.bridge.absorbDeletions(removal.deletes)
        #expect(mac.highlights.byID.isEmpty)
        #expect(await mac.bridge.pendingChanges().deletes.isEmpty)
    }

    @Test func anUnsentLocalEditWinsOverAnIncomingCopy() async throws {
        let phone = Device(), ipad = Device()
        phone.highlights.byID["h1"] = highlight("h1")
        await ipad.bridge.absorb(await phone.send().saves)

        phone.highlights.byID["h1"] = highlight("h1", tags: "phone")
        ipad.highlights.byID["h1"] = highlight("h1", tags: "ipad")
        await phone.bridge.absorb(await ipad.send().saves)
        #expect(phone.highlights.byID["h1"] == highlight("h1", tags: "phone"), "kept: it goes out next")
        #expect(await phone.bridge.pendingChanges().saves.count == 1)
    }

    @Test func conflictsRetryOnTheServerCopyAndExistingEventsSettle() async throws {
        let device = Device()
        let mine = highlight("h1", tags: "mine").toRecord(zoneID: SyncConstants.readerZoneID)
        let server = highlight("h1", tags: "theirs").toRecord(zoneID: SyncConstants.readerZoneID)
        let conflict = CKError(.serverRecordChanged, userInfo: [CKRecordChangedErrorServerRecordKey: server])
        guard case .retry(let retry) = device.bridge.outcome(ofFailedSave: mine, error: conflict) else {
            Issue.record("expected a retry"); return
        }
        #expect(SyncedReaderHighlight(from: retry) == highlight("h1", tags: "mine"))

        let event = SyncedCommentEvent(eventID: "e1", docId: "d", payload: Data("{}".utf8))
            .toRecord(zoneID: SyncConstants.readerZoneID)
        guard case .settled = device.bridge.outcome(ofFailedSave: event, error: conflict) else {
            Issue.record("expected settled"); return
        }
        guard case .notReader = device.bridge.outcome(ofFailedSave: CKRecord(recordType: "SyncedTab"), error: conflict) else {
            Issue.record("expected notReader"); return
        }
    }

    @Test func docIdIsStableAndFileSafe() {
        let id = ReaderCommentDocID.forArticle(urlKey: "https://a.com/x?y=1")
        #expect(id.count == 32 && id.allSatisfy(\.isHexDigit))
        #expect(id == ReaderCommentDocID.forArticle(urlKey: "https://a.com/x?y=1"))
    }
}

@MainActor
@Suite("Reader mirror (Mac copy of the phone's highlights)")
struct ReaderMirrorTests {
    @Test func mirrorPersistsAcrossRelaunchAndCommentsSyncFromIt() async throws {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("mirror-\(UUID().uuidString)")
        let highlight = SyncedReaderHighlight(id: "h1", urlKey: "https://a.com/x", payload: Data(#"{"id":"h1"}"#.utf8))
        let first = ReaderMirror.makeBridge(supportDirectory: support)
        await first.absorb([highlight.toRecord(zoneID: SyncConstants.readerZoneID)])

        // Relaunch: a new mirror reads the file, the ledger says it is confirmed.
        let relaunched = ReaderMirror.makeBridge(supportDirectory: support)
        #expect(await relaunched.pendingChanges().saves.isEmpty)
        #expect(FileManager.default.fileExists(atPath: support.appendingPathComponent("Reader/highlights.json").path))

        // A comment written on the Mac (agent tools, step 4) goes out.
        try await relaunched.comments.openThread(
            docId: ReaderCommentDocID.forArticle(urlKey: highlight.urlKey),
            author: CommentAuthor(kind: .agent, id: "claude"),
            anchor: TextAnchor(from: 0, to: 1, quote: "x"), text: "noted")
        #expect(await relaunched.pendingChanges().saves.map(\.recordType) == [SyncedCommentEvent.recordType])

        relaunched.absorbDeletions([CKRecord.ID(recordName: "hl|h1", zoneID: SyncConstants.readerZoneID)])
        let afterDelete = ReaderMirror(directory: support.appendingPathComponent("Reader"))
        #expect(afterDelete.syncedHighlights().isEmpty)
    }
}
