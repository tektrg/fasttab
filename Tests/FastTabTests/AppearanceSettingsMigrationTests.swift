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
        // The retired "Quick-open items" setting keeps its old key name (loaded, never read).
        #expect(CommandBarAppearance.keys.rowLimit == "FastTab.appearance.quickOpenItemLimit")
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

    // Position picker = the position for shortcut / menu opens. Default (and every store from before
    // the per-open resolver) = Notch; a saved anchor keeps working, the old followsEdge key is ignored.
    @Test func positionDefaultsToNotchAndKeepsSavedChoices() {
        #expect(CommandBarAppearance.placementKey == "FastTab.appearance.placement")
        #expect(CommandBarAppearance.load(from: scratch()).positionChoice == .anchor(.notch))
        // A user who had "Follow hover edge" on keeps whatever anchor was stored.
        let defaults = scratch()
        defaults.set(true, forKey: "FastTab.appearance.followsEdge")
        defaults.set("leftEdge", forKey: "FastTab.appearance.edgeAnchor")
        #expect(CommandBarAppearance.load(from: defaults).positionChoice == .anchor(.leftEdge))
        // A stored floating spot (empty anchor) keeps its placement.
        defaults.set("", forKey: "FastTab.appearance.edgeAnchor")
        defaults.set("bottomRight", forKey: "FastTab.appearance.placement")
        #expect(CommandBarAppearance.load(from: defaults).positionChoice == .anchor(.floating(.bottomRight)))
    }

    @Test func followTheMouseIsStoredAndOffered() {
        #expect(CommandBarAppearance.options.followMouseTitle == "Follow the mouse")
        #expect(CommandBarAppearance.options.offersEdgeAnchors)
        let defaults = scratch()
        var s = CommandBarAppearance.load(from: defaults)
        s.positionChoice = .followMouse
        s.save(to: defaults, keys: CommandBarAppearance.keys)
        #expect(CommandBarAppearance.load(from: defaults).positionChoice == .followMouse)
    }

    // Per-open resolution: ONE rule for what a hover open and a shortcut / menu open show.
    @Test func hoverBottomEdgeOpensAtTheBottomAtThePointer() {
        let position = CommandBarAppearance.standard.resolvedAnchor(
            opening: CommandBarOpenSession.source(revealStyle: .bottomEdge))
        #expect(position == CommandBarResolvedPosition(anchor: .bottomEdge, followsMouse: true))
        let corner = CommandBarAppearance.standard.resolvedAnchor(
            opening: CommandBarOpenSession.source(revealStyle: .bottomLeftCorner))
        #expect(corner.anchor == .corner(.bottomLeft))
    }

    @Test func shortcutOpenFollowsTheMouseWhenChosen() {
        var s = CommandBarAppearance.standard
        s.positionChoice = .followMouse
        let position = s.resolvedAnchor(opening: CommandBarOpenSession.source(revealStyle: nil))
        #expect(position == CommandBarResolvedPosition(anchor: .floating(.center), followsMouse: true))
        // A hover open ignores the saved choice.
        #expect(s.resolvedAnchor(opening: .hover(.leftEdge)).anchor == .leftEdge)
    }

    @Test func shortcutOpenUsesTheSavedAnchorEvenWithAHoverSpotSet() {
        var s = CommandBarAppearance.standard
        s.positionChoice = .anchor(.rightEdge)
        #expect(s.resolvedAnchor(opening: .keyboard) == CommandBarResolvedPosition(anchor: .rightEdge, followsMouse: false))
        s.positionChoice = .anchor(.floating(.center))
        #expect(s.resolvedAnchor(opening: .keyboard) == CommandBarResolvedPosition(anchor: .floating(.center), followsMouse: false))
    }

    // Placement on screen: hover edges slide to the pointer; the notch stays centred; corners stay flush.
    @Test func hoverEdgesSlideToThePointerAndTheNotchStaysCentred() {
        let canvas = CGRect(x: 0, y: 0, width: 1600, height: 1000)
        let visible = canvas
        let pointer = CGPoint(x: 400, y: 500)
        func frame(_ anchor: CommandBarAnchor) -> CGRect {
            CommandBarLayout.surfaceFrame(in: canvas, position: .init(anchor: anchor, followsMouse: true),
                                          pointer: pointer, maxRows: 6, visibleFrame: visible)
        }
        #expect(abs(frame(.bottomEdge).midX - 400) < 0.5)
        #expect(frame(.bottomEdge).minY == canvas.minY)
        #expect(abs(frame(.leftEdge).midY - 500) < 0.5)
        #expect(frame(.leftEdge).minX == canvas.minX)
        #expect(abs(frame(.rightEdge).midY - 500) < 0.5)
        #expect(abs(frame(.notch).midX - canvas.midX) < 0.5)
        #expect(frame(.notch).maxY == canvas.maxY)
    }

    @Test func followTheMouseCentresTheCardOnThePointer() {
        let canvas = CGRect(x: 0, y: 0, width: 1600, height: 1000)
        let pointer = CGPoint(x: 800, y: 500)
        let f = CommandBarLayout.surfaceFrame(in: canvas, position: .init(anchor: .floating(.center), followsMouse: true),
                                              pointer: pointer, maxRows: 6, visibleFrame: canvas)
        #expect(abs(f.midX - 800) < 0.5 && abs(f.midY - 500) < 0.5)
    }

    // Shared anchor: a fixed edge (e.g. Notch) never has to match the hover-to-open edge.
    @Test func fixedEdgeAnchorIsIndependentOfTheHoverEdge() {
        #expect(CommandBarAppearance.keys.edgeAnchor == "FastTab.appearance.edgeAnchor")
        let defaults = scratch()
        var s = CommandBarAppearance.load(from: defaults)
        s.positionChoice = .anchor(.notch)
        s.save(to: defaults, keys: CommandBarAppearance.keys)
        #expect(CommandBarAppearance.load(from: defaults).resolvedAnchor(opening: .keyboard).anchor == .notch)
    }
}
