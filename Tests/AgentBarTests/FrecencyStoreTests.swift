import Foundation
import Testing
import CommandBarKit
@testable import AgentBar

struct FrecencyStoreTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func freshStore() -> FrecencyStore {
        let suite = "AgentBarTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return FrecencyStore(defaults: defaults)
    }

    @Test func emptyStoreLoadsEmpty() {
        #expect(freshStore().load(now: now).isEmpty)
    }

    @Test func roundTripsEntries() {
        let store = freshStore()
        let entries = FrecencyStore.recordingVisit(to: "s1", in: [:], now: now)
        store.save(entries)
        #expect(store.load(now: now) == entries)
    }

    @Test func secondVisitRaisesTheCount() {
        let once = FrecencyStore.recordingVisit(to: "s1", in: [:], now: now)
        let twice = FrecencyStore.recordingVisit(to: "s1", in: once, now: now)
        #expect(once["s1"]?.count == 1)
        #expect(twice["s1"]?.count == 2)
    }

    @Test func staleEntriesAreEvictedOnLoad() {
        let store = freshStore()
        let old = now.addingTimeInterval(-(Frecency.evictionMaxAgeDays + 1) * 86_400)
        store.save(["stale": Frecency.newEntry(now: old), "fresh": Frecency.newEntry(now: now)])
        #expect(Set(store.load(now: now).keys) == ["fresh"])
    }

    @Test func recordingAVisitAlsoDropsStaleEntries() {
        let old = now.addingTimeInterval(-(Frecency.evictionMaxAgeDays + 1) * 86_400)
        let updated = FrecencyStore.recordingVisit(to: "new", in: ["stale": Frecency.newEntry(now: old)], now: now)
        #expect(Set(updated.keys) == ["new"])
    }

    @Test func corruptDataLoadsAsEmpty() {
        let suite = "AgentBarTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(Data("not json".utf8), forKey: FrecencyStore.defaultsKey)
        #expect(FrecencyStore(defaults: defaults).load(now: now).isEmpty)
    }
}
