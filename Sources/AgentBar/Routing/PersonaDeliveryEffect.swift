import Foundation

/// What picking a persona actually does, once its main session's liveness and its own idle-start
/// default are known. Pure derivation — see `PersonaPick.effect`.
enum PersonaDeliveryEffect: Equatable, Sendable {
    /// The persona has a live, message-eligible main session: deliver straight to it.
    case sendToMain
    /// No live main session, and the persona resumes by default: `POST /api/persona/start` with
    /// `fresh: false`.
    case resumeLast
    /// No live main session and the persona starts fresh by default, or the user forced it
    /// (Tab-tag "Start new session"): `POST /api/persona/start` with `fresh: true`.
    case startNew

    /// `forcedStartNew` (Tab on the confirm row, `AgentPanelModel.togglePersonaDeliveryOverride`)
    /// always wins: it is how a live main session gets bypassed on purpose.
    static func derive(hasLiveMain: Bool, idleStart: Persona.IdleStart, forcedStartNew: Bool) -> PersonaDeliveryEffect {
        if forcedStartNew { return .startNew }
        if hasLiveMain { return .sendToMain }
        return idleStart == .resume ? .resumeLast : .startNew
    }

    /// The confirm row's effect phrase, e.g. "→ chief-aptus · send to main session".
    var text: String {
        switch self {
        case .sendToMain: "send to main session"
        case .resumeLast: "resume last conversation"
        case .startNew: "start new session"
        }
    }
}
