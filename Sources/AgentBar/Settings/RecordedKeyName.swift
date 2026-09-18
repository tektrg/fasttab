import AppKit

/// How a just-recorded key is named on screen: keys that print no character
/// (Tab, Space, arrows, F-keys) by name, the rest as the keyboard layout prints them.
enum RecordedKeyName {
    static func name(for event: NSEvent) -> String {
        if let special = KeyDisplayName.specialKeyName(forKeyCode: event.keyCode) { return special }
        let printed = event.charactersIgnoringModifiers?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return printed.isEmpty ? KeyDisplayName.name(forKeyCode: event.keyCode) : printed.uppercased()
    }
}
