import CoreGraphics

/// Gap 9: the panel opened from the corner tab grows out of the bottom-right corner and closes
/// when the pointer leaves it (shared `CommandBarPointerLeaveMonitor`). Opened by the shortcut,
/// none of this applies. Pure geometry and gates; `AgentPanelController` is the glue.
enum CornerPanelLeave {
    /// The corner the panel grows out of: a small square at the display's bottom-right
    /// (AppKit coordinates, y up). Also counts as "not left yet" while the pointer is in it.
    static func cornerZone(displayFrame: CGRect) -> CGRect {
        let side = CornerHotZone.size * 2
        return CGRect(x: displayFrame.maxX - side, y: displayFrame.minY, width: side, height: side)
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
