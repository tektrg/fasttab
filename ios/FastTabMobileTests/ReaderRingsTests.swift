import XCTest
@testable import FastTabMobile

@MainActor
final class ReaderRingsTests: XCTestCase {
    func testValuesClampToUnitRangeAndNonFiniteIsZero() {
        let m = ReaderRingModel(article: 1.7, daily: -0.2, week: .nan)
        XCTAssertEqual(m, ReaderRingModel(article: 1, daily: 0, week: 0))
    }

    func testRoundsToWholePercentSoTinyScrollMovesAreEqual() {
        XCTAssertEqual(ReaderRingModel(article: 0.4001, daily: 0, week: 0),
                       ReaderRingModel(article: 0.4049, daily: 0, week: 0))
    }

    func testAccessibilityLabel() {
        let m = ReaderRingModel(article: 0.4, daily: 0.6, week: 0.3)
        XCTAssertEqual(m.accessibilityLabel, "Article 40%, today 60%, week 30%")
    }

    func testBuiltFromDailyGoalWithWeekAgainstSevenDays() {
        // Goal 1000/day → week target 7000. Week so far 3500; reading half of a 2000-word article
        // from 0 adds 1000 → 4500/7000.
        let goal = ReaderDailyGoal(wordsToday: 500, articleWords: 2_000, highWater: 0, goal: 1_000,
                                   wordsThisWeek: 3_500)
        let m = ReaderRingModel(articleProgress: 0.5, goal: goal)
        XCTAssertEqual(m.article, 0.5)
        XCTAssertEqual(m.daily, 1.0, accuracy: 0.001)       // (500+1000)/1000 clamps to 1
        XCTAssertEqual(m.week, 4_500.0 / 7_000.0, accuracy: 0.01)
    }

    func testNoGoalLeavesDailyAndWeekEmpty() {
        let m = ReaderRingModel(articleProgress: 0.3, goal: nil)
        XCTAssertEqual(m, ReaderRingModel(article: 0.3, daily: 0, week: 0))
    }

    func testStateDoesNotPublishForAnEqualModel() {
        let state = ReaderRingState()
        var count = 0
        let c = state.objectWillChange.sink { _ in count += 1 }
        state.update(ReaderRingModel(article: 0.5, daily: 0, week: 0))
        state.update(ReaderRingModel(article: 0.504, daily: 0, week: 0))
        XCTAssertEqual(count, 1)
        c.cancel()
    }

    func testRingRefreshesOnlyWithCappedProgressWrites() async throws {
        let url = URL(string: "https://example.com/ring-\(UUID().uuidString)")!
        let vm = ReaderViewModel(url: url, title: "Ring", statsRecorder: .isolatedForTests())
        vm.progressPersistInterval = .milliseconds(200)
        vm.loadInitialState()
        var count = 0
        let c = vm.ring.objectWillChange.sink { _ in count += 1 }
        for i in 1...100 { vm.updateScrollProgress(Double(i) * 0.005) }
        XCTAssertEqual(count, 0, "no ring change per scroll tick")
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(count, 1)
        XCTAssertEqual(vm.ring.model.article, 0.5, accuracy: 0.001)
        c.cancel()
    }
}
