import SwiftUI

/// Colour language of the sections.
extension AgentSection {
    var dotColor: Color {
        switch self {
        case .needsYou: .orange
        case .working: .green
        case .parked: .indigo
        case .ended: .gray.opacity(0.45)
        case .sleeping: .clear   // no live status to show
        }
    }
}
