/// The groups the switcher shows, in display order (top to bottom).
///
/// Every live agent that is not working is `needsYou` until the user clears it
/// with Done (finish it) or Park (set it aside, see `TriageState`).
enum AgentSection: Int, CaseIterable, Comparable, Sendable {
    case needsYou
    case working
    case parked
    case ended
    /// Claude Desktop sessions with no running process (`SleepingSessionMapper`); always last.
    case sleeping

    static func < (lhs: AgentSection, rhs: AgentSection) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var title: String {
        switch self {
        case .needsYou: "Needs you"
        case .working: "Working"
        case .parked: "Parked"
        case .ended: "Ended"
        case .sleeping: "Sleeping"
        }
    }
}
