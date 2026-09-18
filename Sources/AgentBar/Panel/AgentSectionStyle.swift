import SwiftUI

/// Colour language of the sections.
extension AgentSection {
    var dotColor: Color {
        switch self {
        case .needsYou: .orange
        case .working: .green
        case .idle: .gray
        case .ended: .gray.opacity(0.45)
        }
    }
}
