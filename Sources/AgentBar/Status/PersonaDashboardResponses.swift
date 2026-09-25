import Foundation

/// `POST /api/persona/start` reply: `{"ok": true, "paneId": "...", "mode": "started"|"resumed"}`
/// or `{"ok": false, "error": "..."}`.
struct DashboardPersonaStartResponse: Decodable {
    let ok: Bool?
    let paneId: String?
    let mode: String?
    let error: String?

    /// The outcome the reply amounts to; nil when it says nothing usable (`ok: true` but missing
    /// `paneId`/a recognized `mode` — the caller turns nil into its own "unreadable reply" text,
    /// same as everywhere else a `nil` decode-result reaches `AgentPanelModel`).
    var outcome: PersonaStartOutcome? {
        guard ok == true else { return error.map(PersonaStartOutcome.failed) }
        guard let paneId else { return nil }
        switch mode {
        case "started": return .started(paneId: paneId)
        case "resumed": return .resumed(paneId: paneId)
        default: return nil
        }
    }
}
