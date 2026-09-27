import Foundation

/// What picking a persona actually does, once its main session's state and its own idle-start
/// default are known. Pure derivation — see `PersonaPick.effect`.
enum PersonaDeliveryEffect: Equatable, Sendable {
    /// The persona has a live, message-eligible main session: deliver straight to it.
    case sendToMain
    /// The persona's main session is live but can't take a message right now: Return starts
    /// nothing and says so — a second session beside one waiting on the user is a duplicate.
    case mainWaitingOnYou
    /// No live main session, and the persona resumes by default: `POST /api/persona/start` with
    /// `fresh: false`.
    case resumeLast
    /// No live main session and the persona starts fresh by default, or the user forced it
    /// (Tab-tag "Start new session"): `POST /api/persona/start` with `fresh: true`.
    case startNew

    /// `forcedStartNew` (Tab on the confirm row, `AgentPanelModel.togglePersonaDeliveryOverride`)
    /// always wins: it is how a live main session gets bypassed on purpose.
    static func derive(mainSession: PersonaMainSession, idleStart: Persona.IdleStart, forcedStartNew: Bool) -> PersonaDeliveryEffect {
        if forcedStartNew { return .startNew }
        switch mainSession {
        case .ready: return .sendToMain
        case .waitingOnYou: return .mainWaitingOnYou
        case .absent: return idleStart == .resume ? .resumeLast : .startNew
        }
    }

    /// The confirm row's effect phrase, e.g. "→ chief-aptus · send to main session".
    var text: String {
        switch self {
        case .sendToMain: "send to main session"
        case .mainWaitingOnYou: "main session is waiting on you"
        case .resumeLast: "resume last conversation"
        case .startNew: "start new session"
        }
    }
}
