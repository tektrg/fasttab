import Foundation

/// The permission card for one agent's open permission box: who, what the agent last
/// said, and the keyboard state of the box itself.
struct PermissionCard: Equatable, Sendable {
    let agentID: String
    let paneId: String
    let label: String
    let projectName: String?
    /// Nil for agents without a Claude session: nothing to read a message from.
    let sessionId: String?
    var state: PermissionCardState
    /// Nil while the transcript is still being read.
    var sessionContext: SessionContext?

    init(agent: AgentSnapshot, paneId: String, prompt: PermissionPrompt) {
        self.agentID = agent.id
        self.paneId = paneId
        self.label = agent.label
        self.projectName = agent.projectName
        self.sessionId = agent.sessionId
        self.state = PermissionCardState(prompt: prompt)
        self.sessionContext = agent.sessionId == nil ? .empty : nil
    }

    /// The agent's latest message from its transcript; nothing when there is none.
    var message: AnswerCard.Message {
        guard let sessionContext else { return .loading }
        return sessionContext.latestMessage.map(AnswerCard.Message.text) ?? .none
    }
}

/// The permission card's tracker: identities are boxes, `next` a box, the "draft" what was decided.
typealias PermissionSendTracker = SendTracker<PermissionDecision, PermissionPrompt>
