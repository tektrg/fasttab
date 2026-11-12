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

    // Slice 8c: accent colour. Stores from before it existed show the system accent (today's look).
    @Test func accentKeyIsFastTabsOwnAndDefaultsToSystem() {
        #expect(CommandBarAppearance.accentKey == "FastTab.appearance.accent")
        let defaults = scratch()
        defaults.set(false, forKey: "FastTab.appearance.outerGlassPanel")
        #expect(CommandBarAppearance.load(from: defaults).accent == .system)
        defaults.set("orange", forKey: "FastTab.appearance.accent")
        #expect(CommandBarAppearance.load(from: defaults).accent == .orange)
    }

    // Slice 10: Position picker. Default (and every store from before it) = follow the hover edge.
    @Test func positionDefaultsToFollowingTheHoverEdge() {
        #expect(CommandBarAppearance.followsEdgeKey == "FastTab.appearance.followsEdge")
        #expect(CommandBarAppearance.placementKey == "FastTab.appearance.placement")
        #expect(CommandBarAppearance.load(from: scratch()).position == nil)
        // An older build may have saved a placement it never showed: still the edge.
        let defaults = scratch()
        defaults.set("bottomRight", forKey: "FastTab.appearance.placement")
        #expect(CommandBarAppearance.load(from: defaults).position == nil)
        defaults.set(false, forKey: "FastTab.appearance.followsEdge")
        #expect(CommandBarAppearance.load(from: defaults).position == .bottomRight)
    }

    @Test func positionPicksTheAnchor() {
        #expect(CommandBarAnchor(revealStyle: .notch, position: CommandBarAppearance.standard.position) == .notch)
        #expect(CommandBarAnchor(revealStyle: .leftEdge, position: CommandBarAppearance.standard.position) == .leftEdge)
        #expect(CommandBarAnchor(revealStyle: .notch, position: .center) == .floating(.center))
    }
}
