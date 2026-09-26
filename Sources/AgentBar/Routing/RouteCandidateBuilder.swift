import Foundation
import CommandBarKit

/// Turns the shown agent rows, plus the persona registry, into one flat list for Jev to choose
/// between — see `.claude/briefs/jev-persona-routing.md`, "Routing (AgentBar)". Pure.
enum RouteCandidateBuilder {
    /// Every persona plus the this-many most recently active sessions — keeps the flat list's
    /// accuracy from dropping as sessions pile up (the brief's own stated risk/mitigation).
    static let sessionCap = 12

    private static let personaIDPrefix = "persona:"

    /// Only rows that can actually take a message today (same rule the Message button uses) become
    /// session candidates; offline personas are never offered. Empty when neither has anything to
    /// offer (`OpenRouterJevClient.route` returns `.none` without a network call for that case).
    static func candidates(
        from agents: [AgentSnapshot],
        personas: [Persona] = [],
        frecency: [String: FrecencyEntry] = [:],
        now: Date = Date()
    ) -> [RouteCandidate] {
        let personaNameByRowID = personaNameByRowID(personas)
        return personaCandidates(personas) + sessionCandidates(agents, personaNameByRowID: personaNameByRowID, frecency: frecency, now: now)
    }

    /// `persona:<name>` → `<name>`; nil for a session pick's plain agent id. The one place that
    /// owns the `persona:` prefix — `AgentPanelModel.finishRouting` uses this to tell a persona
    /// pick apart from a session pick.
    static func personaName(fromCandidateID id: String) -> String? {
        id.hasPrefix(personaIDPrefix) ? String(id.dropFirst(personaIDPrefix.count)) : nil
    }

    private static func personaCandidates(_ personas: [Persona]) -> [RouteCandidate] {
        personas
            .filter { !$0.offline }
            .map { persona in
                let routesWhen = persona.routesWhen.joined(separator: ", ")
                let notFor = persona.notFor.joined(separator: ", ")
                let summary = "\(persona.name) — \(persona.description). Routes here: \(routesWhen). Not for: \(notFor)."
                return RouteCandidate(agentID: "\(personaIDPrefix)\(persona.name)", summary: summary)
            }
    }

    private static func sessionCandidates(
        _ agents: [AgentSnapshot],
        personaNameByRowID: [String: String],
        frecency: [String: FrecencyEntry],
        now: Date
    ) -> [RouteCandidate] {
        let eligible = agents.filter { RowButtons.usableButtons(for: $0).contains(.message) }
        let capped = AgentRanking.orderedByFrecency(eligible, frecency: frecency, now: now).prefix(sessionCap)
        return capped.map { agent in
            let personaLabel = agent.rowId.flatMap { personaNameByRowID[$0] } ?? "no persona"
            var parts = [personaLabel, agent.label, agent.statusText]
            if let excerpt = agent.promptExcerpt, !excerpt.isEmpty {
                parts.append("working on: \(excerpt)")
            }
            return RouteCandidate(agentID: agent.id, summary: parts.joined(separator: " · "))
        }
    }

    /// Every row id (main + every other session) a persona claims, reversed to a lookup — a
    /// session's `rowId` is the same id space `/api/personas` uses for `mainRowId`/`sessionRowIds`.
    private static func personaNameByRowID(_ personas: [Persona]) -> [String: String] {
        var map: [String: String] = [:]
        for persona in personas {
            if let mainRowId = persona.mainRowId { map[mainRowId] = persona.name }
            for rowId in persona.sessionRowIds { map[rowId] = persona.name }
        }
        return map
    }
}
