import Foundation

/// The dashboard's own three-way rule (see the header of chief-dashboard-server.py):
/// the hook is authoritative for "working" (pushed the instant a tool runs);
/// the pane screen is authoritative for blocked-vs-finished (the hook's
/// "blocked" also fires ~60s after a turn ends, so it is never trusted alone).
///
/// AgentBar folds that into two live sections: a live agent is either
/// `working` or `needsYou`. The dashboard's "blocked" vs "finished" split
/// (`isAwaitingPrompt`) no longer decides membership, only what a row says:
/// a real prompt shows the question, a finished agent its last screen line.
/// Parking (`TriageState`) is the user's, applied on top of this.
enum AgentSectionClassifier {
    static func section(
        hookState: String?,
        screenState: String?,
        paneIsInDashboardNeedsYou: Bool
    ) -> AgentSection {
        if isAwaitingPrompt(screenState: screenState, paneIsInDashboardNeedsYou: paneIsInDashboardNeedsYou) {
            return .needsYou
        }
        if hookState == "working" || screenState == "ACTIVE" { return .working }
        return .needsYou
    }

    /// True when the agent is blocked on a real prompt (question / permission),
    /// by the dashboard's rule: its needs-you list, or a screen that needs a human.
    static func isAwaitingPrompt(screenState: String?, paneIsInDashboardNeedsYou: Bool) -> Bool {
        paneIsInDashboardNeedsYou || screenState == "NEEDS_HUMAN"
    }
}
