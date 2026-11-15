import Foundation
import Testing
import IndieEdgeReveal
@testable import AgentBar

@MainActor
struct AgentBarSettingsTests {
    @Test func startsOnDefaults() {
        let settings = AgentBarSettings(defaults: makeScratchDefaults())
        #expect(settings.list == .standard)
        #expect(settings.showsMenuBarIcon)
        #expect(settings.showsCornerTab)
        #expect(settings.hoverSpot == .bottomRightCorner)
        #expect(settings.hotkey == .standard)
        #expect(settings.dashboardBaseURL == DashboardEndpoint.defaultBaseURL)
    }

    @Test func listChangesPersistAcrossInstances() {
        let defaults = makeScratchDefaults()
        AgentBarSettings(defaults: defaults).updateList {
            $0.endedWindowHours = 6
            $0.showsNonClaudePanes = false
        }
        let reloaded = AgentBarSettings(defaults: defaults)
        #expect(reloaded.list.endedWindowHours == 6)
        #expect(!reloaded.list.showsNonClaudePanes)
        #expect(reloaded.list.maxEndedRows == 8)
    }

    @Test func menuBarIconChoicePersists() {
        let defaults = makeScratchDefaults()
        AgentBarSettings(defaults: defaults).setShowsMenuBarIcon(false)
        #expect(!AgentBarSettings(defaults: defaults).showsMenuBarIcon)
    }

    @Test func cornerTabChoicePersists() {
        let defaults = makeScratchDefaults()
        AgentBarSettings(defaults: defaults).setShowsCornerTab(false)
        #expect(!AgentBarSettings(defaults: defaults).showsCornerTab)
        AgentBarSettings(defaults: defaults).setShowsCornerTab(true)
        #expect(AgentBarSettings(defaults: defaults).showsCornerTab)
    }

    // MARK: - Hover spot (shared EdgeRevealStyle)

    @Test func hoverSpotDefaultsToTheBottomRightCornerWhereTheTabAlwaysWas() {
        #expect(AgentBarSettings.defaultHoverSpot == .bottomRightCorner)
        #expect(AgentBarSettings(defaults: makeScratchDefaults()).hoverSpot == .bottomRightCorner)
    }

    @Test func everySpotPersistsUnderItsSharedRawValue() {
        for spot in EdgeRevealStyle.allCases where spot != AgentBarSettings.defaultHoverSpot {
            let defaults = makeScratchDefaults()
            AgentBarSettings(defaults: defaults).setHoverSpot(spot)
            #expect(AgentBarSettings(defaults: defaults).hoverSpot == spot)
            #expect(defaults.string(forKey: "hoverSpot") == spot.rawValue)
        }
        // Choosing the default back writes nothing new but still reads as the default.
        let defaults = makeScratchDefaults()
        let settings = AgentBarSettings(defaults: defaults)
        settings.setHoverSpot(.notch)
        settings.setHoverSpot(.bottomRightCorner)
        #expect(AgentBarSettings(defaults: defaults).hoverSpot == .bottomRightCorner)
    }

    @Test func settingsStoredBeforeHoverSpotsKeepWorking() {
        // An existing user: corner tab turned off, no spot stored.
        let off = makeScratchDefaults()
        off.set(false, forKey: AgentBarSettings.showsCornerTabKey)
        let before = AgentBarSettings(defaults: off)
        #expect(!before.showsCornerTab && before.hoverSpot == .bottomRightCorner)
        // Another: corner tab on (the default), nothing stored at all.
        #expect(AgentBarSettings(defaults: makeScratchDefaults()).showsCornerTab)
    }

    @Test func anUnreadableStoredSpotFallsBackToTheDefault() {
        let defaults = makeScratchDefaults()
        defaults.set("middleOfTheScreen", forKey: "hoverSpot")
        #expect(AgentBarSettings(defaults: defaults).hoverSpot == .bottomRightCorner)
        defaults.set(5, forKey: "hoverSpot")
        #expect(AgentBarSettings(defaults: defaults).hoverSpot == .bottomRightCorner)
    }

    @Test func choosingOffIsKeptAsOff() {
        let defaults = makeScratchDefaults()
        AgentBarSettings(defaults: defaults).setHoverSpot(.off)
        #expect(AgentBarSettings(defaults: defaults).hoverSpot == .off)
    }

    @Test func committedShortcutPersistsAndResetClearsIt() {
        let defaults = makeScratchDefaults()
        let settings = AgentBarSettings(defaults: defaults)
        let chosen = AgentHotkeyConfig(keyCode: 49, modifiers: [.command, .option], keyName: "Space")
        settings.commitHotkey(chosen)
        #expect(AgentBarSettings(defaults: defaults).hotkey == chosen)
        #expect(AgentBarSettings(defaults: defaults).hotkey.displayName == "⌥⌘Space")

        settings.commitHotkey(.standard)
        #expect(defaults.object(forKey: AgentHotkeyConfig.keyCodeDefaultsKey) == nil)
        #expect(AgentBarSettings(defaults: defaults).hotkey == .standard)
    }

    // MARK: - Dashboard address

    @Test func aValidAddressIsSavedAndPublished() {
        let defaults = makeScratchDefaults()
        let settings = AgentBarSettings(defaults: defaults)
        let result = settings.applyDashboardAddress("  http://10.0.0.5:9000 ")
        #expect(result == .valid(URL(string: "http://10.0.0.5:9000")!))
        #expect(settings.dashboardBaseURL.absoluteString == "http://10.0.0.5:9000")
        #expect(AgentBarSettings(defaults: defaults).dashboardBaseURL.absoluteString == "http://10.0.0.5:9000")
    }

    @Test func anInvalidAddressChangesNothingAndSaysWhy() {
        let defaults = makeScratchDefaults()
        let settings = AgentBarSettings(defaults: defaults)
        settings.applyDashboardAddress("http://10.0.0.5:9000")
        for bad in ["", "not a url", "ftp://host", "file:///tmp/x", "http://"] {
            guard case .invalid(let reason) = settings.applyDashboardAddress(bad) else {
                Issue.record("\(bad) should be invalid")
                continue
            }
            #expect(!reason.isEmpty)
            #expect(settings.dashboardBaseURL.absoluteString == "http://10.0.0.5:9000", "\(bad)")
        }
    }

    @Test func applyingTheDefaultAddressStoresNoOverride() {
        let defaults = makeScratchDefaults()
        let settings = AgentBarSettings(defaults: defaults)
        settings.applyDashboardAddress("http://10.0.0.5:9000")
        settings.applyDashboardAddress(DashboardEndpoint.defaultBaseURL.absoluteString)
        #expect(defaults.object(forKey: DashboardEndpoint.baseURLDefaultsKey) == nil)
    }

    @Test func resetGoesBackToTheDefaultAddress() {
        let defaults = makeScratchDefaults()
        let settings = AgentBarSettings(defaults: defaults)
        settings.applyDashboardAddress("http://10.0.0.5:9000")
        settings.resetDashboardAddress()
        #expect(settings.dashboardBaseURL == DashboardEndpoint.defaultBaseURL)
        #expect(defaults.object(forKey: DashboardEndpoint.baseURLDefaultsKey) == nil)
    }

    @Test func theDefaultsWriteFromTheOldDocsStillWorks() {
        let defaults = makeScratchDefaults()
        defaults.set(49, forKey: AgentHotkeyConfig.keyCodeDefaultsKey)   // defaults write ... -int 49
        defaults.set(3, forKey: AgentHotkeyConfig.modifiersDefaultsKey)  // ⌘⌥
        let hotkey = AgentBarSettings(defaults: defaults).hotkey
        #expect(hotkey.keyCode == 49)
        #expect(hotkey.modifiers == [.command, .option])
        #expect(hotkey.displayName == "⌥⌘Space")   // named without a stored key name
    }
}
