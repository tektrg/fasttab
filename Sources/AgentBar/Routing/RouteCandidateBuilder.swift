import Foundation

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
    static func candidates(from agents: [AgentSnapshot], personas: [Persona] = []) -> [RouteCandidate] {
        personaCandidates(personas) + sessionCandidates(agents, personaNameByRowID: personaNameByRowID(personas))
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
                var summary = "\(persona.name) — \(persona.description)."
                if !persona.routesWhen.isEmpty { summary += " Routes here: \(persona.routesWhen.joined(separator: ", "))." }
                if !persona.notFor.isEmpty { summary += " Not for: \(persona.notFor.joined(separator: ", "))." }
                return RouteCandidate(agentID: "\(personaIDPrefix)\(persona.name)", summary: summary)
            }
    }

    private static func sessionCandidates(_ agents: [AgentSnapshot], personaNameByRowID: [String: String]) -> [RouteCandidate] {
        let eligible = agents.filter { RowButtons.usableButtons(for: $0).contains(.message) }
        return orderedByActivity(eligible).prefix(sessionCap).map { agent in
            let personaLabel = agent.rowId.flatMap { personaNameByRowID[$0] } ?? "no persona"
            var parts = [personaLabel, agent.label, agent.statusText]
            if let excerpt = agent.promptExcerpt, !excerpt.isEmpty {
                parts.append("working on: \(excerpt)")
            }
            return RouteCandidate(agentID: agent.id, summary: parts.joined(separator: " · "))
        }
    }

    /// Most recently active first: `secondsInStatus` (the dashboard's `hookSinceSec`) ascending,
    /// rows without one last, dashboard order on ties. How long ago the agent itself last did
    /// something — not how often the user switched to it (frecency), which says nothing about
    /// which session is on the topic right now.
    private static func orderedByActivity(_ agents: [AgentSnapshot]) -> [AgentSnapshot] {
        agents.enumerated().sorted { lhs, rhs in
            let (lhsSeconds, rhsSeconds) = (lhs.element.secondsInStatus ?? .infinity, rhs.element.secondsInStatus ?? .infinity)
            return lhsSeconds != rhsSeconds ? lhsSeconds < rhsSeconds : lhs.offset < rhs.offset
        }.map(\.element)
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
