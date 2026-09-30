import Foundation

/// Where companion-extension setup stands, from the user's point of view.
/// Separates "nothing connected yet" from the two ways a connected extension
/// can still be unusable, so setup UI never shows a bare "Waiting…" for a
/// browser that is in fact connected.
enum ExtensionSetupState: Hashable, Sendable {
    /// Connected, compatible, and FastTab's extension setting is on.
    case usable
    /// Connected and compatible, but the user turned the extension setting off
    /// (Settings > Advanced), so FastTab ignores it.
    case turnedOff
    /// Connected, but only on a protocol version this app doesn't speak.
    case versionMismatch
    /// No browser extension has connected.
    case waiting

    static func resolve(
        extensionEnabled: Bool,
        compatibleAppNames: Set<String>,
        mismatchedAppNames: Set<String>
    ) -> ExtensionSetupState {
        if !compatibleAppNames.isEmpty {
            return extensionEnabled ? .usable : .turnedOff
        }
        return mismatchedAppNames.isEmpty ? .waiting : .versionMismatch
    }
}
