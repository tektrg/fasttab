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

    /// Shuffle is a button on Read (and on Highlights) now, not a tab; Highlights took its place.
    func testReaderOnlyHidesTabsTab() {
        XCTAssertEqual(AppTab.visible(for: .standalone), [.read, .highlights, .more])
        XCTAssertEqual(AppTab.visible(for: .mac), [.read, .tabs, .highlights, .more])
        XCTAssertEqual(AppTab.visible(for: nil), [.read, .tabs, .highlights, .more])
    }

    func testHighlightsTabShowsInBothModes() {
        for mode in [AppMode.standalone, .mac, nil] {
            XCTAssertTrue(AppTab.visible(for: mode).contains(.highlights))
            XCTAssertEqual(AppTab.resolved(.highlights, for: mode), .highlights)
        }
    }

    /// The selected tab is never persisted (every launch opens on Read), so the old Shuffle tab
    /// cannot come back as a stale selection; a tab that disappears on a mode switch falls back to Read.
    func testHiddenTabFallsBackToRead() {
        XCTAssertEqual(AppTab.resolved(.tabs, for: .standalone), .read)
        XCTAssertEqual(AppTab.resolved(.tabs, for: .mac), .tabs)
        XCTAssertEqual(AppTab.resolved(.more, for: .standalone), .more)
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
