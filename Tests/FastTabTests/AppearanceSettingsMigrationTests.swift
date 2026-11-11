import Foundation
import Testing
import IndieCommandBar
@testable import FastTab

/// Slice 8b: Fast Tab's appearance moved onto the shared model. Settings stored by older
/// builds (same keys) must still load unchanged.
struct AppearanceSettingsMigrationTests {
    private func scratch() -> UserDefaults {
        let name = "AppearanceSettingsMigrationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func keysAreTheOldOnes() {
        #expect(CommandBarAppearance.outerPanelKey == "FastTab.appearance.outerGlassPanel")
        #expect(CommandBarAppearance.resultRowStyleKey == "FastTab.appearance.resultRowStyle")
        #expect(CommandBarAppearance.quickOpenItemLimitKey == "FastTab.appearance.quickOpenItemLimit")
    }

    @Test func oldStoredSettingsStillLoad() {
        let defaults = scratch()
        defaults.set(false, forKey: "FastTab.appearance.outerGlassPanel")
        defaults.set("full", forKey: "FastTab.appearance.resultRowStyle")
        defaults.set(11, forKey: "FastTab.appearance.quickOpenItemLimit")
        let loaded = CommandBarAppearance.load(from: defaults)
        #expect(loaded.background == false)
        #expect(loaded.rowStyle == .full)
        #expect(loaded.rowLimit == 11)
    }

    @Test func nothingStoredGivesFastTabDefaults() {
        let loaded = CommandBarAppearance.load(from: scratch())
        #expect(loaded.background)
        #expect(loaded.rowStyle == .minimal)
        #expect(loaded.rowLimit == 5)
    }
}
