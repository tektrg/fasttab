import CoreGraphics
import IndieEdgeReveal

/// Gap 9: the panel opened from the corner tab grows out of its hover spot and closes
/// when the pointer leaves it (shared `CommandBarPointerLeaveMonitor`). Opened by the shortcut,
/// none of this applies. Pure geometry and gates; `AgentPanelController` is the glue.
enum CornerPanelLeave {
    /// The hover spot the panel grows out of on `displayFrame` (AppKit coordinates, y up): the shared
    /// trigger zone of that spot. Also counts as "not left yet" while the pointer is in it.
    /// "Hover to open: Off" grows from the bottom-right, where the corner tab sits.
    static func zone(spot: EdgeRevealStyle, displayFrame: CGRect) -> CGRect {
        let spot = CornerTabPlacement.placementSpot(for: spot)
        return EdgeRevealGeometry.triggerZone(for: spot, screen: EdgeRevealScreenInfo(frame: displayFrame)) ?? .zero
    }
}

extension AgentPanelModel {
    /// Something in the panel is work in progress: leaving it must not close it.
    /// A card (answer / permission / message), New worker mode, a Tab-tag compose, the saved-view
    /// editor, a Jev route in flight, or a row button waiting on "Confirm?".
    var holdsPanelAgainstPointerLeave: Bool {
        if isCardOpen || newWorker != nil || taggedAgentID != nil || pages.editor != nil || routingState != nil { return true }
        return rowActionStates.values.contains { if case .confirming = $0 { true } else { false } }
    }

    /// Blank search box (spaces count as typing).
    var isSearchBoxEmptyForPointerLeave: Bool { query.isEmpty }
}
