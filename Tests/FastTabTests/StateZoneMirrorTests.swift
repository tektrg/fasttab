import Foundation
import CloudKit
import Testing
@testable import FastTab
import FastTabSync

/// The shared change-feed copy of the state zone (reconcile + sync probe),
/// driven by a scripted feed with `Int` tokens.
@MainActor
struct StateZoneMirrorTests {
    private typealias Mirror = StateZoneMirror<Int>
    private struct TokenExpired: Error {}
    private struct NetworkDown: Error {}

    /// Serves scripted pages keyed by the token asked for (nil = full walk),
    /// and records every token asked for. `holdFetches` parks the next fetch
    /// until `releaseHeldFetch()`.
    @MainActor
    private final class ScriptedFeed {
        var pagesBySinceToken: [Int?: Mirror.Page] = [:]
        var expiredTokens: Set<Int> = []
        var failingTokens: Set<Int?> = []
        private(set) var requestedTokens: [Int?] = []
        private(set) var concurrentFetches = 0
        private(set) var maxConcurrentFetches = 0
        var holdFetches = false
        private(set) var heldFetch: CheckedContinuation<Void, Never>?

        func releaseHeldFetch() {
            heldFetch?.resume()
            heldFetch = nil
        }

        func page(since token: Int?) async throws -> Mirror.Page {
            requestedTokens.append(token)
            concurrentFetches += 1
            maxConcurrentFetches = max(maxConcurrentFetches, concurrentFetches)
            defer { concurrentFetches -= 1 }
            if holdFetches {
                await withCheckedContinuation { heldFetch = $0 }
            } else {
                await Task.yield()
            }
            if let token, expiredTokens.contains(token) { throw TokenExpired() }
            if failingTokens.contains(token) { throw NetworkDown() }
            guard let page = pagesBySinceToken[token] else {
                Issue.record("no page scripted for token \(String(describing: token))")
                throw NetworkDown()
            }
            return page
        }
    }

    private static func record(_ name: String) -> CKRecord {
        CKRecord(recordType: SyncedTab.recordType, recordID: CKRecord.ID(recordName: name, zoneID: SyncConstants.stateZoneID))
    }

    private static func page(
        modified: [String] = [], unreadable: [String] = [], deleted: [String] = [],
        token: Int, moreComing: Bool = false
    ) -> Mirror.Page {
        Mirror.Page(
            modifiedRecords: modified.map(record),
            unreadableRecordNames: unreadable,
            deletedRecordNames: deleted,
            token: token,
            moreComing: moreComing
        )
    }

    private func makeMirror(_ feed: ScriptedFeed, now: @escaping () -> Date = Date.init) -> Mirror {
        Mirror(
            fetchPage: { try await feed.page(since: $0) },
            isTokenExpired: { $0 is TokenExpired },
            now: now
        )
    }

    private func names(_ mirror: Mirror) -> Set<String> { Set(mirror.recordsByName.keys) }

    @Test func fullWalkOnceThenOnlyWhatChanged() async throws {
        let feed = ScriptedFeed()
        feed.pagesBySinceToken = [
            nil: Self.page(modified: ["a", "b"], token: 1, moreComing: true),
            1: Self.page(modified: ["c"], deleted: ["a"], token: 2),
        ]
        let mirror = makeMirror(feed)

        let first = try await mirror.catchUp()
        #expect(first == .init(pageCount: 2, wasFullWalk: true))
        #expect(names(mirror) == ["b", "c"])

        feed.pagesBySinceToken[2] = Self.page(deleted: ["c", "never-seen"], token: 3)
        let second = try await mirror.catchUp()
        #expect(second == .init(pageCount: 1, wasFullWalk: false))
        #expect(names(mirror) == ["b"])
        #expect(feed.requestedTokens == [nil, 1, 2])
    }

    @Test func failedWalkResumesFromTheLastAppliedPage() async throws {
        let feed = ScriptedFeed()
        feed.pagesBySinceToken = [
            nil: Self.page(modified: ["a"], token: 1, moreComing: true),
            1: Self.page(modified: ["b"], token: 2),
        ]
        feed.failingTokens = [1]
        let mirror = makeMirror(feed)

        await #expect(throws: NetworkDown.self) { try await mirror.catchUp() }
        feed.failingTokens = []
        try await mirror.catchUp()

        #expect(names(mirror) == ["a", "b"])
        #expect(feed.requestedTokens == [nil, 1, 1])
    }

    @Test func expiredTokenRestartsAFullWalkFromScratch() async throws {
        let feed = ScriptedFeed()
        feed.pagesBySinceToken = [nil: Self.page(modified: ["stale"], token: 1)]
        let mirror = makeMirror(feed)
        try await mirror.catchUp()

        feed.expiredTokens = [1]
        feed.pagesBySinceToken[nil] = Self.page(modified: ["fresh"], token: 5)
        let summary = try await mirror.catchUp()

        #expect(summary.wasFullWalk)
        #expect(names(mirror) == ["fresh"])
    }

    /// An entry the feed could not deliver must not linger as its stale copy
    /// (the probe would answer from it), and clears once it reads again.
    @Test func unreadableEntryDropsItsStaleCopyUntilItReadsAgain() async throws {
        let feed = ScriptedFeed()
        feed.pagesBySinceToken = [
            nil: Self.page(modified: ["a", "b"], token: 1),
            1: Self.page(unreadable: ["a"], token: 2),
            2: Self.page(modified: ["a"], token: 3),
        ]
        let mirror = makeMirror(feed)

        try await mirror.catchUp()
        try await mirror.catchUp()
        #expect(names(mirror) == ["b"])
        #expect(mirror.unreadableRecordNames == ["a"])

        try await mirror.catchUp()
        #expect(names(mirror) == ["a", "b"])
        #expect(mirror.unreadableRecordNames.isEmpty)
    }

    @Test func rebuildsFromAFullWalkOncePerInterval() async throws {
        var now = Date(timeIntervalSince1970: 1_000)
        let feed = ScriptedFeed()
        feed.pagesBySinceToken = [
            nil: Self.page(modified: ["a"], token: 1),
            1: Self.page(token: 1),
        ]
        let mirror = makeMirror(feed, now: { now })
        try await mirror.catchUp()

        now = now.addingTimeInterval(Mirror.fullWalkInterval - 1)
        #expect(try await mirror.catchUp().wasFullWalk == false)

        now = now.addingTimeInterval(1)
        #expect(try await mirror.catchUp().wasFullWalk == true)
        #expect(feed.requestedTokens == [nil, 1, nil])
    }

    /// Two walks writing one token could replay an old page over a newer one.
    @Test func concurrentCatchUpsNeverOverlapAndEachReadsAfterItWasCalled() async throws {
        let feed = ScriptedFeed()
        feed.pagesBySinceToken = [
            nil: Self.page(modified: ["a"], token: 1, moreComing: true),
            1: Self.page(modified: ["b"], token: 2),
            2: Self.page(token: 2),
        ]
        let mirror = makeMirror(feed)

        async let first = mirror.catchUp()
        async let second = mirror.catchUp()
        _ = try await (first, second)

        #expect(feed.maxConcurrentFetches == 1)
        #expect(feed.requestedTokens == [nil, 1, 2])
        #expect(names(mirror) == ["a", "b"])
    }

    /// A caller arriving mid-walk (the probe during the launch walk) waits,
    /// then reads past it; the mirror reads as rebuilding until then.
    @Test func callerArrivingMidWalkWaitsThenWalksAgain() async throws {
        let feed = ScriptedFeed()
        feed.pagesBySinceToken = [
            nil: Self.page(modified: ["a"], token: 1),
            1: Self.page(modified: ["b"], token: 2),
        ]
        feed.holdFetches = true
        let mirror = makeMirror(feed)

        let launchWalk = Task { try await mirror.catchUp() }
        while feed.heldFetch == nil { await Task.yield() }
        let lateCaller = Task { try await mirror.catchUp() }
        await Task.yield()
        #expect(mirror.isRebuilding)
        #expect(feed.requestedTokens == [nil], "late caller must not fetch while the walk runs")

        feed.holdFetches = false
        feed.releaseHeldFetch()
        _ = try await (launchWalk.value, lateCaller.value)

        #expect(feed.requestedTokens == [nil, 1])
        #expect(feed.maxConcurrentFetches == 1)
        #expect(names(mirror) == ["a", "b"])
        #expect(!mirror.isRebuilding)
    }

    /// The mirror fetches only `SyncedDevice.recordFieldKeys`; a phone must
    /// still decode from that, or phone pickup silently stops.
    @Test func deviceDecodesFromOnlyItsDeclaredFieldKeys() {
        let phone = SyncedDevice(id: "PHONE-1", name: "iPhone", modelName: "iPhone", lastSeenAt: Date(timeIntervalSince1970: 1), appVersion: "1.0", kind: .iphone)
        let full = phone.toRecord(zoneID: SyncConstants.stateZoneID)
        let partial = CKRecord(recordType: full.recordType, recordID: full.recordID)
        for key in SyncedDevice.recordFieldKeys { partial[key] = full[key] }
        #expect(SyncedDevice(from: partial) == phone)
    }

    /// Pages fetched for the previous iCloud account must never land in the
    /// mirror of the new one.
    @Test func resetDuringAWalkDiscardsItsPages() async throws {
        let feed = ScriptedFeed()
        feed.pagesBySinceToken = [nil: Self.page(modified: ["old-account"], token: 1)]
        feed.holdFetches = true
        let mirror = makeMirror(feed)

        let walk = Task { try await mirror.catchUp() }
        while feed.heldFetch == nil { await Task.yield() }
        mirror.reset()
        feed.releaseHeldFetch()
        await #expect(throws: Mirror.ResetDuringCatchUp.self) { try await walk.value }
        #expect(mirror.recordsByName.isEmpty)
    }

    /// The old account's request usually fails outright during a switch;
    /// that must read as the reset, not as a sync failure of the new account.
    @Test func resetDuringAFailingFetchReadsAsTheReset() async throws {
        let feed = ScriptedFeed()
        feed.failingTokens = [nil]
        feed.holdFetches = true
        let mirror = makeMirror(feed)

        let walk = Task { try await mirror.catchUp() }
        while feed.heldFetch == nil { await Task.yield() }
        mirror.reset()
        feed.releaseHeldFetch()
        await #expect(throws: Mirror.ResetDuringCatchUp.self) { try await walk.value }
    }
}
