import AppKit
import Foundation
import Testing
@testable import CommandBarKit

/// Hosts storing `ViewShortcut` whole rely on these field names staying stable.
@Test func viewShortcutCodableShapeIsStable() async throws {
    let shortcut = ViewShortcut(keyCode: 19, modifiers: NSEvent.ModifierFlags.option.rawValue, keyName: "2")
    let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(shortcut)) as? [String: Any]

    #expect(Set(json?.keys ?? [:].keys) == ["keyCode", "modifiers", "keyName"])
    let decoded = try JSONDecoder().decode(
        ViewShortcut.self,
        from: Data(#"{"keyCode":19,"modifiers":524288,"keyName":"2"}"#.utf8)
    )
    #expect(decoded == shortcut)
}

@Test func viewShortcutDisplayStringUsesMenuModifierOrder() async throws {
    let flags: NSEvent.ModifierFlags = [.command, .shift, .option, .control]
    let shortcut = ViewShortcut(keyCode: 49, modifiers: flags.rawValue, keyName: "Space")

    #expect(shortcut.displayString == "⌃⌥⇧⌘Space")
}

@Test func viewShortcutKeyNamesSpecialKeysAndUppercasesOthers() async throws {
    #expect(ViewShortcut.keyName(keyCode: 49, characters: " ") == "Space")
    #expect(ViewShortcut.keyName(keyCode: 126, characters: nil) == "↑")
    #expect(ViewShortcut.keyName(keyCode: 11, characters: "b") == "B")
    #expect(ViewShortcut.keyName(keyCode: 999, characters: nil) == "?")
}

@Test func viewShortcutRequiresAModifier() async throws {
    #expect(ViewShortcut.isValid(modifiers: [.command]))
    #expect(!ViewShortcut.isValid(modifiers: []))
    #expect(!ViewShortcut.isValid(modifiers: [.capsLock]))
}
