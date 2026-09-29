import Foundation

/// The message card for one agent: who, what it last said, and the draft with where the send
/// has got to. Pure state; `MessageCardModel` does the sending.
struct MessageCard: Equatable, Sendable {
    static let midTurnConfirmText = "Agent is mid-turn — the message will queue. Press again to send."
    static let waitingOnYouText = "This agent is waiting on you — answer it first."

    enum Phase: Equatable, Sendable {
        case editing
        /// Reading the pane, then the dashboard's reply: the card takes no edits and no second send.
        case sending
    }

    /// What the footer hints should say.
    enum HintMode: Equatable, Sendable {
        case composing
        case confirming
        case sending
    }

    let agentID: String
    /// Typed into the pane, or through a status-only session's inbox (`MessageRoute`).
    let route: MessageRoute
    let rowId: String
    let label: String
    let projectName: String?
    /// What Copy puts on the pasteboard (see `AgentIdentityText`).
    let identityText: String
    /// Nil for agents without a Claude session: nothing to read a message from.
    let sessionId: String?
    private(set) var draft = ""
    /// Pasted or dropped images (at most `MessageImage.maxCount`), sent with the text.
    private(set) var images: [MessageImage] = []
    /// Why the last paste/drop added no image. Cleared by the next edit.
    private(set) var imageHint: String?
    private(set) var phase: Phase = .editing
    /// Set once the dashboard said the agent is mid-turn: the next send press is the confirmed one.
    private(set) var isConfirming = false
    /// Why the last send did not go, in words. Cleared by the next edit or send.
    private(set) var errorText: String?
    /// The last send got no reply: the message may already be in the terminal.
    private(set) var mayHaveGoneThrough = false
    /// Nil while the transcript is still being read.
    var sessionContext: SessionContext?

    init(agent: AgentSnapshot, route: MessageRoute, rowId: String) {
        self.agentID = agent.id
        self.route = route
        self.rowId = rowId
        self.label = agent.label
        self.projectName = agent.projectName
        self.identityText = agent.identityText
        self.sessionId = agent.sessionId
        self.sessionContext = agent.sessionId == nil ? .empty : nil
    }

    // MARK: - Reading

    var verdict: MessageDraftValidator.Verdict {
        MessageDraftValidator.check(draft, allowsQuickCommands: route.allowsQuickCommands, refusesShellPrefix: route.refusesShellPrefix)
    }

    /// One line under the header about how the message travels; nil for a pane.
    var routeCaption: String? { route.caption }

    /// The text a send would put in the agent's input; nil while the draft cannot be sent.
    var sendableText: String? {
        if case .ready(let text) = verdict { return text }
        // Images alone are a message: the dashboard supplies the words.
        if verdict == .empty, !images.isEmpty { return "" }
        return nil
    }

    var canSend: Bool { phase == .editing && sendableText != nil }

    /// The line under the field about the draft itself: why it cannot go, or the counter near the cap.
    var draftHint: String? {
        if let imageHint { return imageHint }
        switch verdict {
        case .slashCommand: return route.commandHint
        case .tooLong(let over): return MessageDraftValidator.tooLongHint(over: over)
        case .empty, .ready: return nil
        }
    }

    var showsLineBreakNote: Bool { MessageDraftValidator.sendsWithLineBreaksFlattened(draft) }

    var counterText: String? {
        guard MessageDraftValidator.showsCounter(for: draft) else { return nil }
        return "\(MessageDraftValidator.sentLength(draft)) / \(MessageDraftValidator.maxLength)"
    }

    var sendTitle: String {
        if isConfirming { return "Send anyway" }
        return mayHaveGoneThrough ? "Send again" : "Send"
    }

    var hintMode: HintMode {
        if phase == .sending { return .sending }
        return isConfirming ? .confirming : .composing
    }

    /// The agent's latest message from its transcript; nothing when there is none.
    var message: AnswerCard.Message {
        guard let sessionContext else { return .loading }
        return sessionContext.latestMessage.map(AnswerCard.Message.text) ?? .none
    }

    // MARK: - Changing

    /// An edit. Ignored while sending. It drops a pending confirmation and any old error: both
    /// were about the previous text.
    mutating func setDraft(_ text: String) {
        guard phase == .editing, text != draft else { return }
        draft = text
        draftChanged()
    }

    static let tooManyImagesHint = "At most \(MessageImage.maxCount) images per message."
    static let unreadableImageHint = "Couldn't read that image (or it stays over 5 MB)."

    /// A paste or drop. `prepared` holds nil for each image that couldn't be read or sized down.
    mutating func addImages(_ prepared: [MessageImage?]) {
        guard phase == .editing, !prepared.isEmpty else { return }
        let readable = prepared.compactMap { $0 }
        let room = MessageImage.maxCount - images.count
        images += readable.prefix(max(0, room))
        draftChanged()
        if readable.count > room { imageHint = Self.tooManyImagesHint }
        else if readable.count < prepared.count { imageHint = Self.unreadableImageHint }
    }

    mutating func removeImage(_ id: UUID) {
        guard phase == .editing else { return }
        images.removeAll { $0.id == id }
        draftChanged()
    }

    /// Anything about what would be sent changed: a pending confirmation and old errors were about the previous draft.
    private mutating func draftChanged() {
        isConfirming = false
        errorText = nil
        imageHint = nil
        mayHaveGoneThrough = false
    }

    /// The send press begins; false when it may not (nothing sendable, or already sending).
    mutating func beginSending() -> Bool {
        guard canSend else { return false }
        phase = .sending
        errorText = nil
        return true
    }

    mutating func stopSending(error: String) {
        phase = .editing
        errorText = error
    }

    mutating func stopSendingNeedingConfirmation() {
        phase = .editing
        errorText = nil
        isConfirming = true
    }

    mutating func stopSendingUncertain(_ text: String) {
        phase = .editing
        errorText = text
        mayHaveGoneThrough = true
    }
}
