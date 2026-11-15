import Foundation
import Testing
import AppKit
import IndieCommandBar
@testable import FastTab

/// ⇧ + the summon shortcut steps back (owner decision 2026-11-14: WRAP). Right after opening
/// (search box, index -1) back goes to the last — oldest — tab and keeps going up; forward past
/// the last row returns to the search box. Driven exactly like `ContentView.wireCycleSession`:
/// each step is `CommandBarController.moveSelection(…, includeSearchField: true)` and reports
/// whether a row is highlighted; releasing the modifier commits only then.
@MainActor
struct BackStepCycleTests {
    @MainActor final class Harness {
        let bar = CommandBarController(isOpen: true, selectedIndex: -1)
        let session: CycleSession
        var committed: [Int] = []

        init(itemCount: Int) {
            session = CycleSession(isShortcutModifierHeld: { !$0.intersection([.control]).isEmpty })
            let bar = self.bar
            session.onAdvance = { direction in
                bar.moveSelection(direction, itemCount: itemCount, includeSearchField: true)
                return bar.selectedIndex != -1
            }
            session.onCommit = { [unowned self] in committed.append(bar.selectedIndex) }
            _ = session.handleFlagsChanged([.control])  // ⌃ held from the opening ⌃Tab
        }
    }

    @Test(arguments: [0, 1, 5, 6, 50])
    func backFromTheSearchBoxWrapsToTheOldestTabThenClimbs(count: Int) {
        let h = Harness(itemCount: count)
        var visited: [Int] = []
        for _ in 0..<min(count, 3) {
            h.session.advance(.backward)
            visited.append(h.bar.selectedIndex)
        }
        #expect(visited == Array((max(0, count - 3)..<count).reversed()))
        if count == 0 {
            h.session.advance(.backward)
            #expect(h.bar.selectedIndex == -1)
            #expect(!h.session.hasCycled)
        }
    }

    @Test(arguments: [1, 5, 6, 50])
    func backwardWalksEveryRowThenTheSearchBox(count: Int) {
        let h = Harness(itemCount: count)
        var visited: [Int] = []
        for _ in 0...count {
            h.session.advance(.backward)
            visited.append(h.bar.selectedIndex)
        }
        #expect(visited == Array((0..<count).reversed()) + [-1])
    }

    @Test(arguments: [1, 5, 6, 50])
    func forwardWalksEveryRowThenBackToTheSearchBox(count: Int) {
        let h = Harness(itemCount: count)
        var visited: [Int] = []
        for _ in 0...count {
            h.session.advance(.forward)
            visited.append(h.bar.selectedIndex)
        }
        #expect(visited == Array(0..<count) + [-1])
    }

    @Test func releasingTheModifierOpensTheHighlightedTab() {
        let h = Harness(itemCount: 6)
        h.session.advance(.backward)   // oldest tab
        h.session.advance(.backward)   // one newer
        #expect(h.session.hasCycled)
        #expect(h.session.handleFlagsChanged([]))
        #expect(h.committed == [4])
    }

    @Test func shiftReleaseAloneDoesNotCommit() {
        // ⌃⇧Tab: letting go of ⇧ first keeps ⌃ held, so nothing opens yet.
        let h = Harness(itemCount: 6)
        _ = h.session.handleFlagsChanged([.control, .shift])
        h.session.advance(.backward)
        #expect(!h.session.handleFlagsChanged([.control]))
        #expect(h.committed.isEmpty)
        #expect(h.session.handleFlagsChanged([]))
        #expect(h.committed == [5])
    }

    @Test func landingOnTheSearchBoxDisarmsTheCommit() {
        let h = Harness(itemCount: 2)
        h.session.advance(.forward)    // row 0
        h.session.advance(.forward)    // row 1
        h.session.advance(.forward)    // search box
        #expect(h.bar.selectedIndex == -1)
        #expect(!h.session.hasCycled)
        #expect(!h.session.handleFlagsChanged([]))
        #expect(h.committed.isEmpty)
    }
}

/// Which ⇧ chords the open bar treats as "back", per summon shortcut.
struct BackStepChordTests {
    typealias R = FastTabKeyRouting

    func route(_ keyCode: UInt16, _ mods: NSEvent.ModifierFlags, summon: R.CycleShortcut, edit: (inout R.Context) -> Void = { _ in }) -> R.Action {
        var c = R.Context()
        c.selectedIndex = 2
        c.selectedRow = .liveTab
        c.cycleShortcuts = [summon]
        edit(&c)
        return R.route(keyCode: keyCode, modifiers: mods, context: c)
    }

    @Test func controlTabSteppingBackIsControlShiftTab() {
        let summon = R.CycleShortcut(keyCode: 48, modifiers: [.control])
        #expect(route(48, [.control, .shift], summon: summon) == .cycleBackward)
        // From the search box, right after opening.
        #expect(route(48, [.control, .shift], summon: summon) { $0.selectedIndex = -1; $0.selectedRow = .none } == .cycleBackward)
    }

    @Test func controlShiftTabIsNotSwallowedByAliasTab() {
        let summon = R.CycleShortcut(keyCode: 48, modifiers: [.control])
        let typingAlias: (inout R.Context) -> Void = { $0.searchTextIsEmpty = false; $0.aliasCommittableByKey = true }
        #expect(route(48, [.control, .shift], summon: summon, edit: typingAlias) == .cycleBackward)
        // Plain Tab still commits the alias; ⌃Tab (only seen here if the global hotkey failed) does not.
        #expect(route(48, [], summon: summon, edit: typingAlias) == .commitAlias)
        #expect(route(48, [.control], summon: summon, edit: typingAlias) == .passThrough)
    }

    @Test func optionQAndACustomShortcutGetTheirShiftTwin() {
        #expect(route(12, [.option, .shift], summon: .init(keyCode: 12, modifiers: [.option])) == .cycleBackward)
        #expect(route(40, [.command, .option, .shift], summon: .init(keyCode: 40, modifiers: [.command, .option])) == .cycleBackward)
        // Other ⇧ chords are not "back".
        #expect(route(13, [.option, .shift], summon: .init(keyCode: 12, modifiers: [.option])) != .cycleBackward)
    }

    @Test func commandShiftSpaceHasNoBackChord() {
        let summon = R.CycleShortcut(keyCode: 49, modifiers: [.command, .shift])
        #expect(route(49, [.command, .shift], summon: summon) != .cycleBackward)
        #expect(route(49, [.command, .shift, .option], summon: summon) != .cycleBackward)
    }
}

/// Settings › Shortcuts caption under the recorder.
struct BackStepCaptionTests {
    @Test func shortcutWithoutShiftNamesItsBackChord() {
        #expect(ShortcutsSettingsView.backStepCaption(modifiers: [.control], keyName: "⇥") == "Press ⇧ + shortcut (⌃⇧⇥) to go back.")
        #expect(ShortcutsSettingsView.backStepCaption(modifiers: [.option], keyName: "Q") == "Press ⇧ + shortcut (⌥⇧Q) to go back.")
    }

    @Test func shortcutWithShiftExplainsWhyThereIsNoBack() {
        #expect(ShortcutsSettingsView.backStepCaption(modifiers: [.command, .shift], keyName: "Space")
                == "Going back (⇧ + shortcut) needs a shortcut without ⇧.")
    }
}
