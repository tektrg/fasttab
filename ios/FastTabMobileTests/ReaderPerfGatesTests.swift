import XCTest
@testable import FastTabMobile

/// Guards for the reader "laggy highlight / phone heats near the end of long articles" fix.
@MainActor
final class ReaderPerfGatesTests: XCTestCase {

    // MARK: - End zone: one signal, one threshold

    func testEndZoneEnterAndExitWithDeadBand() {
        var zone = ReaderEndZone()
        XCTAssertNil(zone.update(progress: 0.5))
        XCTAssertEqual(zone.update(progress: 0.90), true)
        XCTAssertNil(zone.update(progress: 0.89), "inside the dead band: no flip-flop")
        XCTAssertNil(zone.update(progress: 0.95))
        XCTAssertEqual(zone.update(progress: 0.87), false)
        XCTAssertFalse(zone.isAtEnd)
    }

    func testNativeAndPageSignalsAgreeSoTheFlagChangesOncePerCrossing() {
        var zone = ReaderEndZone()
        var changes: [Bool] = []
        // Native scroll tick, then the page's debounced message for the same position, repeated.
        for p in [0.85, 0.91, 0.91, 0.92, 0.92, 0.93, 0.93] {
            if let c = zone.update(progress: p) { changes.append(c) }   // native
            if let c = zone.update(progress: p) { changes.append(c) }   // page
        }
        XCTAssertEqual(changes, [true])
    }

    func testShortArticleFitsCountsAsEndOnce() {
        var zone = ReaderEndZone()
        XCTAssertEqual(zone.contentFits(), true)
        XCTAssertNil(zone.contentFits())
        XCTAssertNil(zone.update(progress: 0.95))
    }

    // MARK: - Rate gate (widget reload)

    func testRateGateAllowsFirstThenWaitsForTheInterval() {
        var gate = ReaderRateGate(minInterval: 30)
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(gate.delay(now: t0), 0)
        gate.markFired(now: t0)
        XCTAssertEqual(gate.delay(now: t0.addingTimeInterval(10)), 20, accuracy: 0.001)
        XCTAssertEqual(gate.delay(now: t0.addingTimeInterval(30)), 0)
        XCTAssertEqual(gate.delay(now: t0.addingTimeInterval(-5)), 0, "clock moved back must not freeze")
    }

    // MARK: - Progress writes across a simulated end-of-article scroll

    func testEndZoneScrollBurstWritesProgressAtBoundedRate() async throws {
        let url = URL(string: "https://example.com/perf-burst-\(UUID().uuidString)")!
        let vm = ReaderViewModel(url: url, title: "Burst", statsRecorder: .isolatedForTests())
        vm.progressPersistInterval = .milliseconds(300)
        vm.loadInitialState()
        let base = vm.persistCount

        // 60 ticks past 90% with a finished-gesture ("scrollend") report each time.
        for i in 0..<60 {
            vm.updateScrollProgress(0.90 + Double(i) * 0.0015, immediate: true)
        }
        XCTAssertEqual(vm.persistCount - base, 0, "mid-article finished gestures coalesce, none writes immediately")

        // Reaching the end persists once; repeated end reports are no-ops.
        for _ in 0..<20 { vm.updateScrollProgress(1, immediate: true) }
        XCTAssertEqual(vm.persistCount - base, 1)

        // Leaving flushes without rewriting the unchanged value.
        vm.flushPendingProgress()
        XCTAssertEqual(vm.persistCount - base, 1)
        XCTAssertEqual(ReaderReadingProgress.shared.progress(for: url), 1, accuracy: 0.001)
    }

    func testContinuousScrollWritesOncePerIntervalNotPerTick() async throws {
        let url = URL(string: "https://example.com/perf-tick-\(UUID().uuidString)")!
        let vm = ReaderViewModel(url: url, title: "Tick", statsRecorder: .isolatedForTests())
        vm.progressPersistInterval = .milliseconds(200)
        vm.loadInitialState()
        let base = vm.persistCount

        for i in 1...100 { vm.updateScrollProgress(Double(i) * 0.005) }
        XCTAssertEqual(vm.persistCount - base, 0)
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(vm.persistCount - base, 1)
    }
}
