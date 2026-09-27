import Foundation

/// What picking a persona actually does, once its main session's state and its own idle-start
/// default are known. Pure derivation — see `PersonaPick.effect`.
enum PersonaDeliveryEffect: Equatable, Sendable {
    /// The persona has a live, message-eligible main session: deliver straight to it.
    case sendToMain
    /// The persona's main session is live but blocked on the user: Return starts nothing and says
    /// so — a second session beside one waiting on the user is a duplicate.
    case mainWaitingOnYou
    /// The persona's main session is live but AgentBar can't message it: Return starts nothing
    /// and says so; Tab (start new session) is the way through.
    case mainUnreachable
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
        case .unreachable: return .mainUnreachable
        case .absent: return idleStart == .resume ? .resumeLast : .startNew
        }
    }

    /// The confirm row's effect phrase, e.g. "→ chief-aptus · send to main session".
    var text: String {
        switch self {
        case .sendToMain: "send to main session"
        case .mainWaitingOnYou: "main session is waiting on you"
        case .mainUnreachable: "main session can't take messages here · tab to start new"
        case .resumeLast: "resume last conversation"
        case .startNew: "start new session"
        }
    }

    /// Return on the confirm row delivers nothing for these: the row stays, and Tab is the only
    /// way to a delivery (a new session).
    var refusesDelivery: Bool {
        self == .mainWaitingOnYou || self == .mainUnreachable
    }
}
