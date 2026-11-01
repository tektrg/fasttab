import Testing
import Foundation
@testable import FastTabSync

/// The phone's manual iCloud sweep: when it runs, and what it must not report as a failure.
@Suite("Zone sweep schedule")
struct ZoneSweepScheduleTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("First sweep is always due")
    func firstSweepDue() {
        #expect(ZoneSweepSchedule.isDue(lastSweptAt: nil, now: now))
    }

    @Test("Not due again before the interval, due once it passes")
    func intervalGate() {
        let interval = ZoneSweepSchedule.interval
        #expect(!ZoneSweepSchedule.isDue(lastSweptAt: now.addingTimeInterval(-(interval - 1)), now: now))
        #expect(ZoneSweepSchedule.isDue(lastSweptAt: now.addingTimeInterval(-interval), now: now))
    }

    @Test("Sweep is far more frequent than the phone's 'Mac offline' threshold")
    func sweepBeatsOfflineThreshold() {
        // A Mac heartbeat lands every heartbeatInterval; the phone must look much more often than that.
        #expect(ZoneSweepSchedule.interval < SyncedDevicePairing.heartbeatInterval)
    }

    @Test("A cancelled task is not a failure; a real error is")
    func cancellationIsNotFailure() {
        #expect(ZoneSweepSchedule.isCancellation(CancellationError()))
        #expect(ZoneSweepSchedule.isCancellation(URLError(.cancelled)))
        #expect(!ZoneSweepSchedule.isCancellation(URLError(.notConnectedToInternet)))
    }
}
