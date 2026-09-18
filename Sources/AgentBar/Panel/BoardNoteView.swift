import SwiftUI

/// Shown when the slow delivery-board feed is stale.
struct BoardNoteView: View {
    var body: some View {
        Text("Ended list / unpushed markers unavailable")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .frame(height: AgentPanelMetrics.noteHeight)
            .background(Color.orange.opacity(0.10))
    }
}
