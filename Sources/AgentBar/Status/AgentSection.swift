/// The four groups the switcher shows, in display order (top to bottom).
enum AgentSection: Int, CaseIterable, Comparable, Sendable {
    case needsYou
    case working
    case idle
    case ended

    static func < (lhs: AgentSection, rhs: AgentSection) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var title: String {
        switch self {
        case .needsYou: "Needs you"
        case .working: "Working"
        case .idle: "Idle / done"
        case .ended: "Ended"
        }
    }
}
