import Foundation

/// Where a persona's main session stands when a pick lands on that persona.
enum PersonaMainSession: Equatable, Sendable {
    /// No main session, or its row is gone, Ended or Sleeping.
    case absent
    /// Live and message-eligible right now.
    case ready(agentID: String)
    /// Live, but it can't take a message right now (blocked on a question or permission, no
    /// hook data, not addressable). Still the persona's session: starting another one beside it
    /// would open a duplicate while this one waits on the user.
    case waitingOnYou(agentID: String)
}

/// A Jev pick that landed on a persona rather than a specific session — the confirm row's
/// `.confirmingPersona` payload (see `AgentPanelModel.RoutingState`).
struct PersonaPick: Equatable, Sendable {
    let persona: Persona
    let confidence: Double
    /// The persona's main session, resolved once when the pick lands (same staleness window
    /// every other pick already tolerates — a `.ready` id is re-resolved against the live
    /// snapshot at delivery time, same as `RoutingState.confirming`'s `agentID`).
    let mainSession: PersonaMainSession
    /// Tab on the confirm row (`AgentPanelModel.togglePersonaDeliveryOverride`) flips this — the
    /// smallest version of the spec's Tab-tag menu that fits a single confirm row: no separate
    /// menu UI, the effect text alone shows which one will happen.
    var forcedStartNew = false

    var effect: PersonaDeliveryEffect {
        .derive(mainSession: mainSession, idleStart: persona.effectiveIdleStart, forcedStartNew: forcedStartNew)
    }
}
