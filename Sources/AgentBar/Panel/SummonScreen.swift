import AppKit
import CommandBarKit

/// The display AgentBar's windows appear on: the one the mouse is on (the main
/// display when it is on none). Shared by the panel and the corner tab so they
/// always land on the same screen.
enum SummonScreen {
    @MainActor
    static func visibleFrame(fallback: CGRect) -> CGRect {
        (NSScreen.containing(NSEvent.mouseLocation) ?? NSScreen.main)?.visibleFrame ?? fallback
    }
}
