import Foundation

/// The answer card for one agent's open question: who, what the agent last
/// said, and the keyboard state of the question itself.
struct AnswerCard: Equatable, Sendable {
    /// What the "latest message" section shows.
    enum Message: Equatable, Sendable {
        case loading
        case text(String)
        /// Nothing to show: the section is left out.
        case none
    }

    let agentID: String
    let paneId: String
    let label: String
    let projectName: String?
    /// What Copy puts on the pasteboard (see `AgentIdentityText`).
    let identityText: String
    /// Nil for agents without a Claude session (opencode): nothing to read a message from.
    let sessionId: String?
    var state: AnswerCardState
    /// Set when the question is one tab of a multi-question form: the card then shows every
    /// question at once (`state` keeps the question the terminal was on when it opened).
    var form: AnswerFormState?
    /// Nil while the transcript is still being read.
    var sessionContext: SessionContext?

    init(agent: AgentSnapshot, paneId: String, question: AnswerableQuestion) {
        self.agentID = agent.id
        self.paneId = paneId
        self.label = agent.label
        self.projectName = agent.projectName
        self.identityText = agent.identityText
        self.sessionId = agent.sessionId
        self.state = AnswerCardState(question: question)
        // No session to read: nothing is loading.
        self.sessionContext = agent.sessionId == nil ? .empty : nil
    }

    /// What the footer hints should say.
    var hintMode: AnswerCardState.HintMode {
        guard let form else { return state.hintMode }
        return form.isEditable ? .form : .formBusy
    }

    /// The agent's latest message from its transcript, else the dashboard's
    /// copy of the prose above the picker, else nothing.
    var message: Message {
        guard let sessionContext else { return .loading }
        if let text = sessionContext.latestMessage { return .text(text) }
        if let context = state.question.context?.trimmingCharacters(in: .whitespacesAndNewlines), !context.isEmpty {
            return .text(context)
        }
        return .none
    }

    /// Best-effort "likely plan" link; only ever a file that exists.
    var planFile: URL? { sessionContext?.planFile }
}

/// What the agent's session transcript tells us about the question in front of it.
struct SessionContext: Equatable, Sendable {
    let latestMessage: String?
    let planFile: URL?

    static let empty = SessionContext(latestMessage: nil, planFile: nil)
}
