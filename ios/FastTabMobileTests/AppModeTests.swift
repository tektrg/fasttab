import XCTest
@testable import FastTabMobile

/// Reader only vs Mac companion: stored mode, upgrade migration, one-way auto-switch,
/// which root tabs show, and which share sheet buttons appear.
@MainActor
final class AppModeTests: XCTestCase {

    private func makeStore() -> AppModeStore {
        let suiteName = "AppModeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return AppModeStore(defaults: defaults)
    }

    // MARK: - Store

    func testModeRoundTrips() {
        let store = makeStore()
        XCTAssertNil(store.mode)
        store.mode = .standalone
        XCTAssertEqual(store.mode, .standalone)
        store.mode = .mac
        XCTAssertEqual(AppModeStore(defaults: store.defaults).mode, .mac)
    }

    func testResolveKeepsStoredChoice() {
        XCTAssertEqual(AppModeStore.resolve(stored: .standalone, onboardingCompleted: true, hasCachedMac: true), .standalone)
    }

    func testResolveMigratesExistingUsersToMac() {
        XCTAssertEqual(AppModeStore.resolve(stored: nil, onboardingCompleted: true, hasCachedMac: false), .mac)
        XCTAssertEqual(AppModeStore.resolve(stored: nil, onboardingCompleted: false, hasCachedMac: true), .mac)
    }

    func testResolveLeavesNewUsersUndecided() {
        XCTAssertNil(AppModeStore.resolve(stored: nil, onboardingCompleted: false, hasCachedMac: false))
    }

    func testResolveAndPersistWritesMigration() {
        let store = makeStore()
        XCTAssertEqual(store.resolveAndPersist(onboardingCompleted: true, hasCachedMac: false), .mac)
        XCTAssertEqual(store.mode, .mac, "persisted so the share extension sees it")
        let fresh = makeStore()
        XCTAssertNil(fresh.resolveAndPersist(onboardingCompleted: false, hasCachedMac: false))
        XCTAssertNil(fresh.mode)
    }

    // MARK: - Auto-switch

    func testMacAppearingSwitchesReaderOnlyToMacOneWay() {
        XCTAssertEqual(AppModeStore.modeAfterMacAppeared(current: .standalone), .mac)
        XCTAssertEqual(AppModeStore.modeAfterMacAppeared(current: .mac), .mac)
        XCTAssertNil(AppModeStore.modeAfterMacAppeared(current: nil), "undecided stays undecided")
    }

    func testModelReportsSwitchOnlyOnce() {
        let model = AppModeModel(store: makeStore())
        model.set(.standalone)
        XCTAssertTrue(model.macAppeared())
        XCTAssertEqual(model.mode, .mac)
        XCTAssertFalse(model.macAppeared(), "already mac: no second toast")
    }

    // MARK: - Root tabs

    func testReaderOnlyHidesTabsTab() {
        XCTAssertEqual(AppTab.visible(for: .standalone), [.read, .shuffle, .more])
        XCTAssertEqual(AppTab.visible(for: .mac), [.read, .tabs, .shuffle, .more])
        XCTAssertEqual(AppTab.visible(for: nil), [.read, .tabs, .shuffle, .more])
    }

    func testHiddenTabFallsBackToRead() {
        XCTAssertEqual(AppTab.resolved(.tabs, for: .standalone), .read)
        XCTAssertEqual(AppTab.resolved(.shuffle, for: .standalone), .shuffle)
        XCTAssertEqual(AppTab.resolved(.tabs, for: .mac), .tabs)
    }

    // MARK: - Share sheet

    func testShareOptionsPerMode() {
        XCTAssertEqual(ShareOptions.for(mode: .standalone), [.saveToIPhone])
        XCTAssertEqual(ShareOptions.for(mode: .mac), [.sendToMac, .saveToIPhone])
        XCTAssertEqual(ShareOptions.for(mode: nil), [.sendToMac, .saveToIPhone])
    }

    // MARK: - Mac wording

    func testIntelligenceTipDropsBookmarkFoldersForReaderOnly() {
        XCTAssertFalse(IntelligenceTip.message(isStandalone: true).contains("bookmark"))
        XCTAssertTrue(IntelligenceTip.message(isStandalone: false).contains("bookmark folders"))
    }

    func testOpenTabsWidgetCopyPerMode() {
        let readerOnly = OpenTabsWidgetCopy.for(mode: .standalone)
        XCTAssertFalse(readerOnly.showsTabs)
        XCTAssertEqual(readerOnly.emptyMessage, "Open Tabs needs FastTab on your Mac.")
        XCTAssertTrue(OpenTabsWidgetCopy.for(mode: .mac).showsTabs)
        XCTAssertEqual(OpenTabsWidgetCopy.for(mode: nil), OpenTabsWidgetCopy.for(mode: .mac))
    }
}
