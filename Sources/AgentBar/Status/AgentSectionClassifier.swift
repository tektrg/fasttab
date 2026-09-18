import Foundation

/// The dashboard's own three-way rule (see the header of chief-dashboard-server.py):
/// the hook is authoritative for "working" (pushed the instant a tool runs);
/// the pane screen is authoritative for blocked-vs-finished (the hook's
/// "blocked" also fires ~60s after a turn ends, so it is never trusted alone).
enum AgentSectionClassifier {
    static func section(
        hookState: String?,
        screenState: String?,
        paneIsInDashboardNeedsYou: Bool
    ) -> AgentSection {
        if paneIsInDashboardNeedsYou || screenState == "NEEDS_HUMAN" { return .needsYou }
        if hookState == "working" || screenState == "ACTIVE" { return .working }
        return .idle
    }
}
