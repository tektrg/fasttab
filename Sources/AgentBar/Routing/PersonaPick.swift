import Foundation

/// A Jev pick that landed on a persona rather than a specific session — the confirm row's
/// `.confirmingPersona` payload (see `AgentPanelModel.RoutingState`).
struct PersonaPick: Equatable, Sendable {
    let persona: Persona
    let confidence: Double
    /// The persona's main session's agent id, resolved once when the pick lands (same staleness
    /// window every other pick already tolerates — re-resolved against the live snapshot at
    /// delivery time, same as `RoutingState.confirming`'s `agentID`). Nil = no live, message-
    /// eligible main session.
    let mainAgentID: String?
    /// Tab on the confirm row (`AgentPanelModel.togglePersonaDeliveryOverride`) flips this — the
    /// smallest version of the spec's Tab-tag menu that fits a single confirm row: no separate
    /// menu UI, the effect text alone shows which one will happen.
    var forcedStartNew = false

    var effect: PersonaDeliveryEffect {
        .derive(hasLiveMain: mainAgentID != nil, idleStart: persona.effectiveIdleStart, forcedStartNew: forcedStartNew)
    }
}
