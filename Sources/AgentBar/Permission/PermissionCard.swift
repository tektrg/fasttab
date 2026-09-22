import Foundation

/// The permission card for one agent's open permission box: who, what the agent last
/// said, and the keyboard state of the box itself.
struct PermissionCard: Equatable, Sendable {
    let agentID: String
    /// herdr can reassign this while the card stays open (same session, new pane): kept current by
    /// `PermissionCardModel.reconcile(with:)`, never by anything that reads what the box says.
    var paneId: String
    let label: String
    let projectName: String?
    /// What Copy puts on the pasteboard (see `AgentIdentityText`).
    let identityText: String
    /// Nil for agents without a Claude session: nothing to read a message from.
    let sessionId: String?
    var state: PermissionCardState
    /// Set instead of `state` being used when the box is a plan-approval box (Claude's plan mode): the
    /// same card (agent, last message) with the plan and the box's own rows in place of Allow / Deny.
    var plan: PlanCardState?
    /// The plan file the box names, for a plan card.
    var planFile: PlanFile = .loading
    /// The path `planFile` was requested for (a different path read from the pane means a new read).
    var planFileRequestedPath: String?
    /// Set when a send from this agent went through but the dashboard warned about where the pane ended up.
    var sentWarning: String?
    /// Nil while the transcript is still being read.
    var sessionContext: SessionContext?

    init(agent: AgentSnapshot, paneId: String, prompt: PermissionPrompt) {
        self.agentID = agent.id
        self.paneId = paneId
        self.label = agent.label
        self.projectName = agent.projectName
        self.identityText = agent.identityText
        self.sessionId = agent.sessionId
        self.state = PermissionCardState(prompt: prompt)
        if prompt.isPlan {
            self.plan = PlanCardState(prompt: prompt)
            self.planFile = prompt.planPath == nil ? .noPath : .loading
        }
        self.sessionContext = agent.sessionId == nil ? .empty : nil
    }

    /// The pane has been read: `live` is the box it shows now, nil when it shows none. A box of the other kind
    /// (a tool box where a plan box was, or the reverse) is never adopted: the card's rows mean something else.
    mutating func resolve(live: PermissionPrompt?, failure: String?) {
        var live = live, failure = failure
        if let shown = live, shown.isPlan != (plan != nil) {
            live = nil
            failure = "The terminal now shows a different kind of prompt than this card was opened for. Open it again."
        }
        if plan != nil { plan?.resolve(live: live, failure: failure) } else { state.resolve(live: live, failure: failure) }
    }

    /// What the footer hints should say.
    var hintMode: PermissionCardState.HintMode { plan?.hintMode ?? state.hintMode }

    /// The agent's latest message from its transcript; nothing when there is none.
    var message: AnswerCard.Message {
        guard let sessionContext else { return .loading }
        return sessionContext.latestMessage.map(AnswerCard.Message.text) ?? .none
    }
}

/// The permission card's tracker: identities are boxes, `next` a box, the "draft" what was decided.
typealias PermissionSendTracker = SendTracker<PermissionDecision, PermissionPrompt>
