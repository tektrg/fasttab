import Foundation
import Testing
@testable import CommandBarKit

// MARK: - Score / decay math

@Test func scoreIsCountAtZeroDelta() async throws {
    let now = Date()
    let entry = FrecencyEntry(count: 4, lastVisit: now, cachedScore: 4, cachedScoreAt: now)
    #expect(abs(Frecency.score(entry, now: now) - 4.0) < 1e-9)
}

@Test func scoreHalvesAtOneHalfLife() async throws {
    let now = Date()
    let threeDaysAgo = now.addingTimeInterval(-3 * 86_400)
    let entry = FrecencyEntry(count: 4, lastVisit: threeDaysAgo, cachedScore: 4, cachedScoreAt: threeDaysAgo)
    #expect(abs(Frecency.score(entry, now: now) - 2.0) < 1e-6)
}

@Test func scoreFutureTimestampClampsToCount() async throws {
    let now = Date()
    let futureEntry = FrecencyEntry(
        count: 10,
        lastVisit: now.addingTimeInterval(3_600),
        cachedScore: 10,
        cachedScoreAt: now
    )
    #expect(abs(Frecency.score(futureEntry, now: now) - 10.0) < 1e-9)
}

@Test func applyVisitAccumulatesDecayedCount() async throws {
    let now = Date()
    let threeDaysAgo = now.addingTimeInterval(-3 * 86_400)
    var entry = FrecencyEntry(count: 4, lastVisit: threeDaysAgo, cachedScore: 4, cachedScoreAt: threeDaysAgo)
    Frecency.applyVisit(&entry, weight: 1.0, now: now)
    // Decayed count (2.0) + new visit (1.0) = 3.0
    #expect(abs(entry.count - 3.0) < 1e-6)
    #expect(entry.lastVisit == now)
}

@Test func applyVisitOnFreshEntryEqualsCountPlusWeight() async throws {
    let now = Date()
    var entry = Frecency.newEntry(weight: 1.0, now: now)
    Frecency.applyVisit(&entry, weight: 1.0, now: now)
    #expect(abs(entry.count - 2.0) < 1e-9)
}

// MARK: - Eviction

@Test func shouldEvictAfterMaxAge() async throws {
    let now = Date()
    let veryOld = now.addingTimeInterval(-22 * 86_400)
    let entry = FrecencyEntry(count: 5, lastVisit: veryOld, cachedScore: 5, cachedScoreAt: veryOld)
    #expect(Frecency.shouldEvict(entry, now: now))
}

@Test func shouldNotEvictWithinMaxAge() async throws {
    let now = Date()
    let recent = now.addingTimeInterval(-7 * 86_400)
    let entry = FrecencyEntry(count: 5, lastVisit: recent, cachedScore: 5, cachedScoreAt: recent)
    #expect(!Frecency.shouldEvict(entry, now: now))
}
