import Foundation

/// Where a persona's main session stands when a pick lands on that persona.
enum PersonaMainSession: Equatable, Sendable {
    /// No main session, or its row is gone, Ended or Sleeping.
    case absent
    /// Live and message-eligible right now.
    case ready(agentID: String)
    /// Live, but blocked on a question or permission box. Still the persona's session: starting
    /// another one beside it would open a duplicate while this one waits on the user.
    case waitingOnYou(agentID: String)
    /// Live, not blocked, but AgentBar can't message it at all (no pane, no hook data yet, not
    /// addressable). Only an explicit Tab "start new session" delivers anywhere.
    case unreachable(agentID: String)
}

/// A Jev pick that landed on a persona rather than a specific session — the confirm row's
/// `.confirmingPersona` payload (see `AgentPanelModel.RoutingState`).
struct PersonaPick: Equatable, Sendable {
    private(set) var persona: Persona
    let confidence: Double
    /// The persona's main session, resolved when the pick lands and again at Return
    /// (`AgentPanelModel.deliverPersonaPick`): a changed effect updates the confirm row instead of
    /// acting on what the row no longer says.
    var mainSession: PersonaMainSession
    /// Tab on the confirm row (`AgentPanelModel.togglePersonaDeliveryOverride`) flips this — the
    /// smallest version of the spec's Tab-tag menu that fits a single confirm row: no separate
    /// menu UI, the effect text alone shows which one will happen.
    var forcedStartNew = false
    /// The machine chip selected on the confirm row (Left/Right, `moveMachine(by:)`); starts as the
    /// persona's own `runsOn`. Nil when the dashboard sends no machine routing (older dashboard).
    var machineID: String?
    /// Set after a start came back `.unreachable`: the row moved its chip to the dashboard's
    /// `retryOn` and says why, so one more Return starts there (never retried silently).
    var unreachableHint: String?

    init(persona: Persona, confidence: Double, mainSession: PersonaMainSession) {
        self.persona = persona
        self.confidence = confidence
        self.mainSession = mainSession
        self.machineID = persona.runsOn
    }

    var effect: PersonaDeliveryEffect {
        .derive(mainSession: mainSession, idleStart: persona.effectiveIdleStart, forcedStartNew: forcedStartNew)
    }
}

// MARK: - Machine chips

extension PersonaPick {
    /// The machines drawn as chips, e.g. `[Pro] [Air]`: only when there is a real choice (2+) and
    /// Return would start something — a send to a live main session has no machine to pick.
    var machineChips: [PersonaMachine] {
        guard let machines = persona.machines, machines.count > 1, machineID != nil else { return [] }
        switch effect {
        case .resumeLast, .startNew: return machines
        case .sendToMain, .mainWaitingOnYou, .mainUnreachable: return []
        }
    }

    /// The `machine` sent with `POST /api/persona/start`: always the selected chip when the
    /// dashboard supports machine routing (equal to `runsOn` by default — explicit is harmless,
    /// and the reply's chosen machine never depends on the server re-reading the registry).
    var startMachineID: String? { machineID }

    /// Left/Right on the confirm row: moves the selected chip, clamped at both ends. False when no
    /// chips are showing, so the arrow keeps its usual job (moving the text cursor).
    mutating func moveMachine(by step: Int) -> Bool {
        let chips = machineChips
        guard !chips.isEmpty else { return false }
        let current = chips.firstIndex { $0.id == machineID } ?? 0
        let next = min(max(current + step, 0), chips.count - 1)
        machineID = chips[next].id
        unreachableHint = nil
        return true
    }

    /// After an unreachable start: select `retryOn` (adding it if the row didn't list it) and keep
    /// the dashboard's own reason plus the one-press way forward on the row.
    mutating func offerRetry(on machine: PersonaMachine, reason: String) {
        if persona.machines?.contains(where: { $0.id == machine.id }) == false {
            persona.machines?.append(machine)
        }
        machineID = machine.id
        unreachableHint = "\(reason) Return to start on \(machine.label)."
    }
}

