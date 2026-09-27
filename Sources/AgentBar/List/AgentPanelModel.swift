import Foundation
import Combine
import CommandBarKit

/// Observable state behind the panel: the latest snapshot, the search text,
/// the selection, the user's frecency and parked agents, and the row buttons
/// (Done / Park / Close pane), the pane peek and the answer card (`answer`).
/// All derivation lives in the pure `AgentListBuilder` / `AgentSelection` /
/// `FrecencyStore` / `TriageState` / `RowActionMachine`.
@MainActor
final class AgentPanelModel: ObservableObject {
    @Published private(set) var snapshot: StatusSnapshot?
    @Published private(set) var presentation: AgentListPresentation = .connecting
    /// Moving the selection drops any keyboard-highlighted button, and follows into the hierarchy
    /// model so ⌘]/⌘[/⌘⌫ and a "Report to…"/"Stop reporting" menu press act on the same row.
    @Published private(set) var selectedAgentID: String? {
        didSet {
            if selectedAgentID != oldValue { highlightedButton = nil }
            treeModel.selectedNodeID = selectedAgentID
        }
    }
    /// Who reports to whom (`Tree/`), nested straight into this list — see `AgentListGrouping`.
    /// Republishes through this model (same shape as `answer`/`permission`/`message`) so the panel
    /// view needs only observe `AgentPanelModel`.
    let treeModel: AgentTreeModel
    /// The selected row's button the keyboard is on (←/→), if any; ↩ presses it.
    @Published private(set) var highlightedButton: RowButton?
    /// Where each row's Done / Close pane press has got to (see `RowActionState`).
    @Published private(set) var rowActionStates: [String: RowActionState] = [:]
    /// Bumped on every show so the search field re-grabs keyboard focus.
    @Published private(set) var focusRequest = 0
    /// Typing re-filters and always jumps back to the first row.
    @Published var query = "" {
        didSet {
            guard query != oldValue else { return }
            rebuild()
            selectedAgentID = presentation.selectableAgentIDs.first
            closePeek()
        }
    }

    /// The pane-screen peek (Space), or nil while the list shows.
    @Published private(set) var peek: PanePeek?

    /// Where a peek reads the pane screen from; set by the host, and replaced
    /// when the user points AgentBar at another dashboard.
    var statusSource: (any AgentStatusSource)? {
        didSet {
            answer.statusSource = statusSource
            permission.statusSource = statusSource
            message.statusSource = statusSource
            blockerProbe.statusSource = statusSource
        }
    }

    /// Answering a blocked agent's question (replaces the list while open). Its
    /// changes republish through this model, so views need observe only this.
    let answer: AnswerCardModel

    /// Approving or denying a blocked agent's permission box (replaces the list while open).
    /// Same republishing as `answer`.
    let permission: PermissionCardModel

    /// Typing a line to a working / idle agent (replaces the list while open). Same republishing as `answer`.
    let message: MessageCardModel

    /// Copy of an agent's identifying text to the pasteboard, and the "Copied" feedback.
    let copier: IdentityCopier

    /// A card (answer, permission or message) is showing in place of the list.
    var isCardOpen: Bool { answer.isOpen || permission.isOpen || message.isOpen }

    /// A failed switch or row action (stays until the user dismisses or replaces it), else a shortcut problem.
    @Published private(set) var footerNotice: PanelFooterNotice?

    /// Shift+Return routing (see `Routing/`): Jev is picking a candidate, or has picked one and
    /// is waiting for a confirming Return (Settings > Routing > "After routing"). nil the rest
    /// of the time — a failure never lands here, it goes to `footerNotice` like a failed message
    /// send does, and clears back to nil at once.
    enum RoutingState: Equatable {
        case loading
        case confirming(agentID: String, label: String, confidence: Double)
        /// A persona pick, shown on the same confirm row (`→ <persona> · <effect text>`). Tab flips
        /// `PersonaPick.forcedStartNew` (`togglePersonaDeliveryOverride()`); Return delivers via
        /// `deliverPersonaPick(_:)`.
        case confirmingPersona(PersonaPick)
        /// `POST /api/persona/start` is in flight. Return is swallowed the same way `.loading` is.
        case startingPersona(name: String)
    }
    @Published private(set) var routingState: RoutingState?
    /// The exact text Jev was asked about, captured at Shift+Return. A route always acts on this,
    /// never on `query` again — the box is not locked while Jev thinks, so the user may keep
    /// typing; that must never let a confirmed send carry text Jev never saw.
    private var routingText = ""

    /// Where the OpenRouter key lives; set by the host. No key = routing always fails fast,
    /// telling the user where to set it up rather than guessing.
    var routingAPIKeyStore: (any RoutingAPIKeyStoring)?
    /// The dashboard's persona registry; set by the host, replaced on dashboard switch like
    /// `statusSource`. Nil, or any failure fetching from it, means routing falls back to
    /// sessions-only candidates — never a footer notice, since this runs on every route start.
    var personaSource: (any PersonaDirectorySource)?
    /// Model id + confirm-first/send-immediately + system prompt, from Settings > Routing; applied
    /// live by `apply(_:)`.
    private(set) var routingSettings = RoutingSettings.standard
    /// Test seam: the real client hits OpenRouter; tests inject a fake.
    var makeRoutingClient: (_ apiKey: String, _ model: String, _ systemPrompt: String) -> any JevRoutingClient = { apiKey, model, systemPrompt in
        OpenRouterJevClient(apiKey: apiKey, model: model, systemPrompt: systemPrompt)
    }
    /// Bumped on every route so a reply for a route the user already left behind is dropped.
    private var routingEpoch = 0

    /// A headless send (Jev routing, Tab-tag compose, quick commands) that failed with "nothing
    /// reached the agent" and is waiting on a retry, keyed by agent id. `attempt` is the attempt
    /// number just made (1 = the original try); it doubles as a lightweight guard against a stale
    /// scheduled retry firing after a fresh send (or `useDashboard()`) has already superseded it —
    /// see `retryDirectSend`. An `.uncertain` reply is never queued here (see `sendDirectMessage`'s
    /// doc comment): it might already be sitting typed in the agent's input box.
    private struct PendingDirectSend { let text: String; var attempt: Int }
    private var pendingDirectSends: [String: PendingDirectSend] = [:]
    /// Attempts (including the first) before a headless send gives up; delay before each retry.
    /// Configurable only so tests don't have to wait out real time.
    private let directSendRetryDelays: [TimeInterval]
    private var maxDirectSendAttempts: Int { directSendRetryDelays.count + 1 }

    /// New routing settings from Settings > Routing; applies to the next route, never an in-flight one.
    /// Named apart from `apply(_ settings: AgentListSettings)`: overloading it made `.standard`
    /// ambiguous at every existing call site (both types have a static `standard`).
    func applyRouting(_ settings: RoutingSettings) {
        routingSettings = settings
    }

    /// Shift+Return with text in the box: asks Jev which shown, message-eligible agent should get
    /// it. No-op with an empty box, a card open, or a route already running (one at a time, like
    /// a message send). The box is not cleared: a failure leaves the text exactly as typed.
    func startRouting() {
        guard !isCardOpen, routingState == nil, taggedAgentID == nil else { return }
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard let apiKey = routingAPIKeyStore?.get(), !apiKey.isEmpty else {
            showAnswerNotice("Set an OpenRouter key in Settings > Routing first.")
            return
        }
        guard let snapshot else {
            showAnswerNotice("No agents to route to yet.")
            return
        }
        let agents = AgentListBuilder.shownAgents(in: snapshot, settings: listSettings, triage: triage)
        routingState = .loading
        routingText = text
        let client = makeRoutingClient(apiKey, routingSettings.modelID, routingSettings.systemPrompt)
        let epoch = routingEpoch
        let afterRouting = routingSettings.afterRouting
        let personaSource = personaSource
        let frecency = frecency
        let asOf = now()
        Task { [weak self] in
            // Nil (unreachable dashboard, timeout, bad reply) reads as "no personas" — sessions-only
            // candidates, same as before personas existed; may also be empty (zero message-eligible
            // agents shown and no personas) — `OpenRouterJevClient.route` returns `.none` for that
            // without a network call.
            let personas = await personaSource?.fetchPersonas() ?? []
            let candidates = RouteCandidateBuilder.candidates(from: agents, personas: personas, frecency: frecency, now: asOf)
            let outcome = await client.route(text: text, candidates: candidates)
            self?.finishRouting(outcome, candidates: candidates, personas: personas, epoch: epoch, afterRouting: afterRouting)
        }
    }

    private func finishRouting(_ outcome: RouteOutcome, candidates: [RouteCandidate], personas: [Persona], epoch: Int, afterRouting: AfterRoutingBehavior) {
        guard epoch == routingEpoch, routingState == .loading else { return }
        switch outcome {
        case .none:
            routingState = nil
            showAnswerNotice("No agent can take a message right now.")
        case .failed(let reason):
            routingState = nil
            showAnswerNotice(reason)
        case .picked(let pickedID, let confidence):
            // Never act on Jev's raw echo: it must name one of the candidates this exact round
            // actually offered, not merely any agent/persona that happens to still exist.
            guard candidates.contains(where: { $0.agentID == pickedID }) else {
                routingState = nil
                showAnswerNotice("Jev picked an agent that is no longer shown.")
                return
            }
            if let personaName = RouteCandidateBuilder.personaName(fromCandidateID: pickedID) {
                resolvePersonaPick(named: personaName, personas: personas, confidence: confidence, afterRouting: afterRouting)
                return
            }
            guard let agent = presentation.agents.first(where: { $0.id == pickedID }) ?? snapshot?.agents.first(where: { $0.id == pickedID })
            else {
                routingState = nil
                showAnswerNotice("Jev picked an agent that is no longer shown.")
                return
            }
            if afterRouting == .sendImmediately {
                send(to: agent)
            } else {
                routingState = .confirming(agentID: pickedID, label: agent.label, confidence: confidence)
            }
        }
    }

    // MARK: - Persona picks

    /// `finishRouting` found a `persona:<name>` pick: resolves where its main session stands, then
    /// either shows the persona confirm row or, under "send immediately", delivers straight away.
    private func resolvePersonaPick(named name: String, personas: [Persona], confidence: Double, afterRouting: AfterRoutingBehavior) {
        guard let persona = personas.first(where: { $0.name == name }) else {
            routingState = nil
            showAnswerNotice("Jev picked a persona that is no longer offered.")
            return
        }
        let pick = PersonaPick(persona: persona, confidence: confidence, mainSession: mainSession(of: persona))
        if afterRouting == .sendImmediately {
            deliverPersonaPick(pick)
        } else {
            routingState = .confirmingPersona(pick)
        }
    }

    /// The persona's main session as shown right now — the same staleness window a plain session
    /// pick already tolerates at confirm time (`confirmRoutingIfPending`), just resolved up front
    /// here: a persona confirm row needs to know this to choose its effect text before the user
    /// ever presses Return. "Live" and "can take a message" are kept apart on purpose: a live main
    /// session that can't take one must not read as absent, or Return starts a duplicate beside it.
    private func mainSession(of persona: Persona) -> PersonaMainSession {
        guard let mainRowId = persona.mainRowId,
              let agent = presentation.agents.first(where: { $0.rowId == mainRowId }) ?? snapshot?.agents.first(where: { $0.rowId == mainRowId }),
              agent.section.isLive
        else { return .absent }
        return RowButtons.usableButtons(for: agent).contains(.message) ? .ready(agentID: agent.id) : .waitingOnYou(agentID: agent.id)
    }

    /// Tab while `.confirmingPersona` is showing: the smallest version of the spec's Tab-tag menu
    /// that fits a single confirm row — no existing "menu" mechanism was found (`tagSelected()` is a
    /// *different* Tab meaning: tagging a selected row as the send target, which doesn't apply here
    /// since a persona pick has no single row to tag). Flips between the persona's own default
    /// delivery and an explicit "start new session"; the effect text alone shows which one will
    /// happen. False when there was no persona confirm row to toggle.
    @discardableResult
    func togglePersonaDeliveryOverride() -> Bool {
        guard case .confirmingPersona(var pick) = routingState else { return false }
        pick.forcedStartNew.toggle()
        routingState = .confirmingPersona(pick)
        return true
    }

    /// Return while `.confirmingPersona`, or "send immediately" landing on a persona: sends to the
    /// live main session through the exact same pipeline a plain session pick uses, or starts/resumes
    /// the persona through the dashboard.
    private func deliverPersonaPick(_ pick: PersonaPick) {
        switch pick.effect {
        case .sendToMain:
            guard case .ready(let mainAgentID) = pick.mainSession,
                  let agent = presentation.agents.first(where: { $0.id == mainAgentID }) ?? snapshot?.agents.first(where: { $0.id == mainAgentID })
            else {
                routingEpoch += 1
                routingState = nil
                showAnswerNotice("\(pick.persona.name)'s main session is no longer shown.")
                return
            }
            send(to: agent)
        case .mainWaitingOnYou:
            // Starts nothing, and keeps the typed text for a re-send once the main session is free.
            routingEpoch += 1
            routingState = nil
            showAnswerNotice("\(pick.persona.name)'s main session is waiting on you. Answer it, then send again.")
        case .resumeLast:
            startPersonaSession(pick.persona, fresh: false)
        case .startNew:
            startPersonaSession(pick.persona, fresh: true)
        }
    }

    /// `POST /api/persona/start`, reached only through `deliverPersonaPick`. Runs the exact same
    /// `MessageDraftValidator` check every other send does first — a persona start is not exempt
    /// from the empty/slash-command/too-long rules `send(to:)` and `sendToTaggedIfPending()` apply.
    private func startPersonaSession(_ persona: Persona, fresh: Bool) {
        routingEpoch += 1
        switch MessageDraftValidator.check(routingText) {
        case .empty:
            routingState = nil
            showAnswerNotice("Nothing to send.")
        case .slashCommand:
            routingState = nil
            showAnswerNotice(MessageDraftValidator.slashCommandHint)
        case .tooLong(let over):
            routingState = nil
            showAnswerNotice(MessageDraftValidator.tooLongHint(over: over))
        case .ready(let text):
            guard let personaSource else {
                routingState = nil
                showAnswerNotice("No status dashboard to start \(persona.name) on.")
                return
            }
            routingState = .startingPersona(name: persona.name)
            let epoch = routingEpoch
            Task { [weak self] in
                let outcome = await personaSource.startPersona(persona.name, text: text, fresh: fresh)
                self?.finishPersonaStart(outcome, personaName: persona.name, epoch: epoch)
            }
        }
    }

    /// The `POST /api/persona/start` reply: never auto-retried, whatever it says (spec) — a failure
    /// just shows the reason, the same as every other send failure.
    private func finishPersonaStart(_ outcome: PersonaStartOutcome, personaName: String, epoch: Int) {
        guard epoch == routingEpoch, case .startingPersona = routingState else { return }
        routingState = nil
        switch outcome {
        case .started:
            query = ""
            showFailureNotice(.created("Started \(personaName)"))
        case .resumed:
            query = ""
            showFailureNotice(.created("Resumed \(personaName)"))
        case .failed(let reason):
            showAnswerNotice(reason)
        }
    }

    /// Return while a route is `.confirming`: sends. Returns false so `activateSelected` falls
    /// through to its normal handling otherwise.
    private func confirmRoutingIfPending() -> Bool {
        switch routingState {
        case .confirming(let agentID, _, _):
            guard let agent = presentation.agents.first(where: { $0.id == agentID }) ?? snapshot?.agents.first(where: { $0.id == agentID })
            else { return false }
            send(to: agent)
            return true
        case .confirmingPersona(let pick):
            deliverPersonaPick(pick)
            return true
        case .loading, .startingPersona, nil:
            return false
        }
    }

    /// Return while a route is `.loading` ("Asking Jev…"): swallowed. Nothing has been picked yet,
    /// so a plain Return here must not fall through to the normal activate/switch path (it would
    /// otherwise press whatever row happens to be highlighted — a surprising, unrelated action
    /// firing mid-route). Named explicitly, mirroring `confirmRoutingIfPending()`, so every
    /// in-flight `RoutingState` case is handled the same deliberate way in `activateSelected`.
    private func isRoutingInFlight() -> Bool {
        switch routingState {
        case .loading, .startingPersona: true
        case .confirming, .confirmingPersona, nil: false
        }
    }

    /// Hands `routingText` to the Message pipeline (its own pane guard, one-flight-per-agent
    /// tracking, row labels and sticky note all apply unchanged), clears the route, and clears
    /// the search box — even if the user kept typing into it while Jev thought (see `routingText`).
    /// Runs through the same `MessageDraftValidator` the Message card's `pressSend()` uses first,
    /// so pasted/typed newlines are flattened to spaces (never refused by the dashboard) and a
    /// slash command or over-length draft is refused here, the same as it would be on that card,
    /// rather than silently sent or dropped. A refusal keeps the typed text in the box, like any
    /// other routing failure.
    private func send(to agent: AgentSnapshot) {
        routingEpoch += 1
        routingState = nil
        switch MessageDraftValidator.check(routingText) {
        case .empty:
            showAnswerNotice("Nothing to send.")
        case .slashCommand:
            showAnswerNotice(MessageDraftValidator.slashCommandHint)
        case .tooLong(let over):
            showAnswerNotice(MessageDraftValidator.tooLongHint(over: over))
        case .ready(let text):
            guard sendDirectMessage(to: agent, text: text) else { return }
            query = ""
        }
    }

    /// `message.sendDirect`, plus the retry shared by every direct-send path — Jev routing,
    /// Tab-tag compose, and the row menu's Compact/Clear (`RowActionPlan.sendQuickCommand`). Two
    /// failure shapes get a few quick automatic retries before the footer notice shows: the row
    /// not being message-eligible right this instant (it just became blocked, or a previous send
    /// to it is still finishing — nothing was sent either way) and a `.failed` dashboard reply
    /// (refused before typing anything). An `.uncertain` reply (may already be typed into the
    /// agent's input box) is handled by `handleDirectSendOutcome` and never reaches here again —
    /// retrying that one could paste the message twice.
    @discardableResult
    private func sendDirectMessage(to agent: AgentSnapshot, text: String, attempt: Int = 1) -> Bool {
        if attempt == 1, pendingDirectSends[agent.id] != nil {
            showAnswerNotice("Still retrying an earlier message to \(agent.label) — wait a moment before sending another.")
            return false
        }
        pendingDirectSends[agent.id] = PendingDirectSend(text: text, attempt: attempt)
        guard message.sendDirect(to: agent, text: text) else {
            retryDirectSendOrGiveUp(agentID: agent.id, label: agent.label, text: text, attempt: attempt, reason: "it can no longer take a message")
            return false
        }
        return true
    }

    /// Every outcome of a headless send (`message.onDirectSendOutcome`) — `sendDirect` itself only
    /// reports whether an attempt *started*.
    private func handleDirectSendOutcome(agentID: String, label: String, text: String, outcome: MessageSendOutcome) {
        switch outcome {
        case .sent:
            pendingDirectSends.removeValue(forKey: agentID)
        case .failed(let reason):
            // A missing entry means this reply is for a send `useDashboard()` (or a give-up) already
            // superseded — drop it rather than default to attempt 1 and start a fresh retry cycle for
            // a request nothing is tracking any more.
            guard let attempt = pendingDirectSends[agentID]?.attempt else { return }
            retryDirectSendOrGiveUp(agentID: agentID, label: label, text: text, attempt: attempt, reason: reason)
        case .needsConfirmation:
            // `sendDirect` always sends `confirmed: true` (see its doc comment), so this should not
            // occur in practice; handled defensively, same wording the card uses, no retry.
            pendingDirectSends.removeValue(forKey: agentID)
            showAnswerNotice("Message to \(label) not sent: the agent is mid-turn. Open Message again to queue it.")
        case .uncertain(let reason):
            pendingDirectSends.removeValue(forKey: agentID)
            showAnswerNotice("Message to \(label): \(reason)")
        }
    }

    /// `attempt` is the attempt just made. One more try after a short delay, or the give-up notice
    /// once `maxDirectSendAttempts` is used up.
    private func retryDirectSendOrGiveUp(agentID: String, label: String, text: String, attempt: Int, reason: String) {
        guard attempt < maxDirectSendAttempts else {
            pendingDirectSends.removeValue(forKey: agentID)
            showAnswerNotice("Couldn't send to \(label) after \(maxDirectSendAttempts) tries: \(reason)")
            return
        }
        let delay = directSendRetryDelays[attempt - 1]
        let nextAttempt = attempt + 1
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            self?.retryDirectSend(agentID: agentID, text: text, attempt: nextAttempt)
        }
    }

    /// Fired after a retry's delay. Dropped if a fresh send (or `useDashboard()`) has since
    /// superseded this one (`pendingDirectSends[agentID]` no longer names the attempt that just
    /// failed) or the agent is no longer shown.
    private func retryDirectSend(agentID: String, text: String, attempt: Int) {
        guard pendingDirectSends[agentID]?.attempt == attempt - 1 else { return }
        guard let agent = presentation.agents.first(where: { $0.id == agentID }) ?? snapshot?.agents.first(where: { $0.id == agentID }) else {
            pendingDirectSends.removeValue(forKey: agentID)
            showAnswerNotice("Couldn't send: that agent is no longer shown.")
            return
        }
        sendDirectMessage(to: agent, text: text, attempt: attempt)
    }

    /// Esc while routing: cancels back to the plain search box (the typed text stays). True whenever
    /// there was a route to cancel (there is no `isCardOpen`-style flag for routing the way
    /// `message.isOpen` gives the message card that same interception "for free").
    private func cancelRoutingIfActive() -> Bool {
        guard routingState != nil else { return false }
        routingEpoch += 1
        routingState = nil
        return true
    }

    // MARK: - Tag (Tab picks an explicit send target, an alternative to asking Jev)

    /// Tab on a selected, message-eligible row: locks it as the send target. The search box keeps
    /// working as a normal text field — typing fills it, Return sends to this agent instead of the
    /// usual press/switch handling. One at a time, like `routingState`; nil the rest of the time.
    @Published private(set) var taggedAgentID: String?

    /// Refreshed alongside every live sighting of the tagged agent (`tagSelected()`, `reconcileTag()`)
    /// so `taggedAgentLabel` has something to fall back on when a live lookup momentarily can't find
    /// the agent — a feed outage deliberately empties `presentation.agents`/`snapshot.agents` and
    /// `reconcileTag()` is deliberately skipped while it lasts (the tag itself must survive the blip,
    /// see `receive()`), so without this the label alone would flicker to nil independently of
    /// `taggedAgentID`, even though every OTHER piece of tagged/composing state stays keyed on
    /// `taggedAgentID` (window sizing, list-hiding) — the exact mismatch a live-vs-cached label would
    /// otherwise cause: chip disappears, icon/height revert to untagged, but the list stays hidden
    /// and the window still budgets room for a chip that isn't drawn.
    private var taggedAgentLastKnownLabel: String?

    /// The tagged agent's label, for the chip/placeholder in the search box; nil only once the tag
    /// itself is nil (the live lookup failing on its own, e.g. mid-outage, falls back to the last
    /// known label instead — see `taggedAgentLastKnownLabel`).
    var taggedAgentLabel: String? {
        guard taggedAgentID != nil else { return nil }
        return liveTaggedAgentLabel ?? taggedAgentLastKnownLabel
    }

    private var liveTaggedAgentLabel: String? {
        taggedAgentID.flatMap { id in
            (presentation.agents.first { $0.id == id } ?? snapshot?.agents.first { $0.id == id })?.label
        }
    }

    /// Tab: tags the selected row if it can take a message (same eligibility `RowButtons` already
    /// gates the Message button with). Re-tagging — arrow to another row, Tab again — just swaps the
    /// target; typed text is untouched. Cancels an in-flight Jev route: the two are mutually
    /// exclusive, and an explicit tag makes asking Jev redundant. No-op while a card is open, or
    /// when nothing selectable is message-eligible.
    func tagSelected() {
        guard !isCardOpen, let agent = selectedAgent, RowButtons.usableButtons(for: agent).contains(.message) else { return }
        let wasRouting = cancelRoutingIfActive()
        // Same as every card-opening path below: composing hides the list/peek area entirely
        // (AgentPanelView, AgentPanelMetrics.isComposing), so a Peek left open behind the tag
        // would render against a window sized as if nothing were shown.
        closePeek()
        // Only on the FIRST tag, and only if the box wasn't already a message-in-progress (Jev
        // routing, just cancelled above, treats the box as the message to route — tagging instead
        // is picking the target explicitly, not starting over). Otherwise whatever's in the box is
        // just the search term used to find this row, not the start of a message, so it must not
        // become one. Re-tagging (already composing, Tab to a different row) is a third case —
        // that box already holds a drafted message, which must survive the target swap too (see
        // `retaggingSwapsTheTargetWithoutTouchingTypedText`).
        if taggedAgentID == nil, !wasRouting { query = "" }
        taggedAgentID = agent.id
        taggedAgentLastKnownLabel = agent.label
        // Tagging USED TO swap `SearchFieldView`'s body between two different `if`/`else` branches
        // (the chip's own row existed only in the tagged one) — a structural identity change that
        // tore the old field down and inserted a brand-new one, so the actual first-responder
        // handoff sometimes didn't survive even though `@FocusState` looked fine (AGENTS.md gotcha
        // 18). Fixed at the view level instead: `field` now has exactly one call site in
        // `SearchFieldView.body`, in a row that's unconditionally present either way, so it's never
        // torn down. This bump is kept only as cheap defense-in-depth (harmless either way) —
        // it is no longer load-bearing for that bug.
        DispatchQueue.main.async { [weak self] in self?.focusRequest += 1 }
    }

    /// The chip's ✕ (`TagChipView` in `SearchFieldView`): same effect as Esc while tagged.
    func removeTag() {
        _ = cancelTagIfActive()
    }

    /// Esc while tagged: clears the tag, typed text stays. False when there was nothing to clear, so
    /// Esc goes on to its other jobs (mirrors `cancelRoutingIfActive()`).
    private func cancelTagIfActive() -> Bool {
        guard taggedAgentID != nil else { return false }
        taggedAgentID = nil
        taggedAgentLastKnownLabel = nil
        return true
    }

    /// Return while tagged: sends the box's text straight to the tagged agent through the same
    /// guarded pipeline a Jev-routed send uses (`MessageCardModel.sendDirect` — pre-send pane
    /// re-read, busy-agent confirmation, the lot), then clears the box and the tag. True whenever a
    /// tag was pending (whether or not the send itself went through), so `activateSelected` never
    /// falls through to its normal press/switch handling while tagged.
    @discardableResult
    private func sendToTaggedIfPending() -> Bool {
        guard let agentID = taggedAgentID,
              let agent = presentation.agents.first(where: { $0.id == agentID }) ?? snapshot?.agents.first(where: { $0.id == agentID })
        else { return false }
        switch MessageDraftValidator.check(query) {
        case .empty:
            showAnswerNotice("Nothing to send.")
        case .slashCommand:
            showAnswerNotice(MessageDraftValidator.slashCommandHint)
        case .tooLong(let over):
            showAnswerNotice(MessageDraftValidator.tooLongHint(over: over))
        case .ready(let text):
            guard sendDirectMessage(to: agent, text: text) else { return true }
            query = ""
            taggedAgentID = nil
        }
        return true
    }

    /// Every status update: the tagged agent may have stopped being message-eligible while the user
    /// was still typing (finished, disconnected). Clears the tag and says so once, rather than let a
    /// later Return silently fail against a stale target.
    private func reconcileTag() {
        guard let agentID = taggedAgentID else { return }
        let agent = presentation.agents.first(where: { $0.id == agentID }) ?? snapshot?.agents.first(where: { $0.id == agentID })
        guard let agent, RowButtons.usableButtons(for: agent).contains(.message) else {
            taggedAgentID = nil
            taggedAgentLastKnownLabel = nil
            showAnswerNotice("\(agent?.label ?? "That agent") can no longer take a message — tag cleared.")
            return
        }
        // Only ever reached on a healthy reading (`receive()` skips this call during an outage), so
        // this is always a genuine live sighting — safe to trust for a rename, never a stale/outage read.
        taggedAgentLastKnownLabel = agent.label
    }

    // MARK: - Routed notes (what a routed send left on the receiving row)

    /// Newest first. Only the user clears one (`clearRoutedNote`); nothing here expires on its own.
    @Published private(set) var routedNotesByAgentID: [String: [RoutedNote]] = [:]

    /// The notes still on `agentID`'s row, newest first.
    func routedNotes(for agentID: String) -> [RoutedNote] {
        routedNotesByAgentID[agentID] ?? []
    }

    private func recordRoutedNote(agentID: String, text: String) {
        var notes = routedNotesByAgentID[agentID] ?? []
        notes.insert(RoutedNote(id: UUID(), text: text, sentAt: now()), at: 0)
        routedNotesByAgentID[agentID] = notes
        routedNoteStore.save(routedNotesByAgentID)
    }

    /// ✕ on a note: the only way one goes away.
    func clearRoutedNote(_ noteID: UUID, for agentID: String) {
        guard var notes = routedNotesByAgentID[agentID] else { return }
        notes.removeAll { $0.id == noteID }
        if notes.isEmpty { routedNotesByAgentID.removeValue(forKey: agentID) } else { routedNotesByAgentID[agentID] = notes }
        routedNoteStore.save(routedNotesByAgentID)
    }

    /// An agent gone from the feed entirely (not merely `.ended`, which can still show briefly)
    /// takes its notes with it — there is no row left to show them on. A dead feed reports no
    /// agents at all, so it must never read as "everyone left" and wipe every note.
    private func pruneRoutedNotes(keeping agents: [AgentSnapshot]) {
        let liveIDs = Set(agents.map(\.id))
        let staleIDs = routedNotesByAgentID.keys.filter { !liveIDs.contains($0) }
        guard !staleIDs.isEmpty else { return }
        for id in staleIDs { routedNotesByAgentID.removeValue(forKey: id) }
        routedNoteStore.save(routedNotesByAgentID)
    }

    /// What the user chose to show (Settings > List); changes apply at once.
    @Published private(set) var listSettings: AgentListSettings

    /// Where the status feed is expected, for the "feed down" message.
    @Published private(set) var dashboardAddress: String

    /// Called when the user activates a row (Enter, click, or release after
    /// cycling). The host closes the panel and switches to the agent; frecency
    /// is recorded later, by `recordSwitch`, once the switch worked.
    var onActivate: (AgentSnapshot) -> Void = { _ in }

    /// Called when an agent enters Needs you (see `NeedsYouArrivalDetector`);
    /// the host shows the corner tab.
    var onNeedsYouArrival: (CornerTabContent) -> Void = { _ in }

    /// Called on every reading of Needs you, after `onNeedsYouArrival`, with the newcomers (empty
    /// most times) and everyone in it now (nil when the feed is down). Blockers are as the panel
    /// shows them, so a question learned late arrives here as a later reading. The host plays the
    /// alert sounds and keeps the corner tab sticky from it.
    var onNeedsYouReading: (_ arrivals: [AgentSnapshot], _ needsYou: [AgentSnapshot]?) -> Void = { _, _ in }

    private let store: FrecencyStore
    private let triageStore: TriageStore
    private let routedNoteStore: RoutedNoteStore
    private let now: () -> Date
    private let completedHoldSeconds: TimeInterval
    private var frecency: [String: FrecencyEntry]
    private var triage: TriageState
    private var failureNotice: PanelFooterNotice?
    private var hotkeyIssue: String?
    private let peekLoader = LatestResultLoader<PaneScreenResult>()
    /// Peek on a status-only row (no pane): reads the session transcript's latest message.
    private let peekMessageLoader = LatestResultLoader<SessionContext>()
    private let loadPeekMessage: AnswerCardModel.SessionContextLoad
    private var arrivalDetector = NeedsYouArrivalDetector()
    private var blockerMemory = BlockerMemory()
    private let blockerProbe: BlockerProbe
    /// The latest reading as the dashboard sent it, to derive the shown rows again when the probe learns something.
    private var lastReceived: StatusSnapshot?
    private var answerObservation: AnyCancellable?
    private var permissionObservation: AnyCancellable?
    private var messageObservation: AnyCancellable?
    private var copierObservation: AnyCancellable?
    private var treeObservation: AnyCancellable?
    private var treeErrorObservation: AnyCancellable?
    private var treeInfoObservation: AnyCancellable?

    init(
        store: FrecencyStore = FrecencyStore(),
        triageStore: TriageStore = TriageStore(),
        routedNoteStore: RoutedNoteStore = RoutedNoteStore(),
        listSettings: AgentListSettings = .standard,
        dashboardAddress: String = DashboardEndpoint(baseURL: DashboardEndpoint.defaultBaseURL).displayAddress,
        completedHoldSeconds: TimeInterval = 8,
        answer: AnswerCardModel = AnswerCardModel(),
        permission: PermissionCardModel = PermissionCardModel(),
        message: MessageCardModel = MessageCardModel(),
        copier: IdentityCopier = IdentityCopier(),
        blockerProbe: BlockerProbe = BlockerProbe(),
        directSendRetryDelays: [TimeInterval] = [5, 10],
        treeModel: AgentTreeModel = AgentTreeModel(),
        loadPeekMessage: @escaping AnswerCardModel.SessionContextLoad = AnswerCardModel.readTranscript,
        now: @escaping () -> Date = { Date() }
    ) {
        self.loadPeekMessage = loadPeekMessage
        self.answer = answer
        self.permission = permission
        self.message = message
        self.copier = copier
        self.blockerProbe = blockerProbe
        self.directSendRetryDelays = directSendRetryDelays
        self.treeModel = treeModel
        self.store = store
        self.triageStore = triageStore
        self.routedNoteStore = routedNoteStore
        self.triage = triageStore.load()
        self.completedHoldSeconds = completedHoldSeconds
        self.listSettings = listSettings
        self.dashboardAddress = dashboardAddress
        self.now = now
        self.frecency = store.load(now: now())
        self.routedNotesByAgentID = routedNoteStore.load()
        wireAnswerCard()
        wirePermissionCard()
        wireMessageCard()
        wireBlockerProbe()
        wireTreeModel()
        copierObservation = copier.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    private func wireAnswerCard() {
        answerObservation = answer.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        answer.onNotice = { [weak self] sentence in self?.showAnswerNotice(sentence) }
        answer.onAnswered = { [weak self] agentID in self?.advanceSelection(pastAnswered: agentID) }
        answer.onReleaseKeyboard = { [weak self] in self?.focusRequest += 1 }
        answer.consumeEscape = { [weak self] in self?.dismissFooterNotice() ?? false }
    }

    private func wirePermissionCard() {
        permissionObservation = permission.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        permission.onNotice = { [weak self] sentence in self?.showAnswerNotice(sentence) }
        permission.onWarning = { [weak self] sentence in self?.showFailureNotice(.warning(sentence)) }
        permission.onDecided = { [weak self] agentID in self?.advanceSelection(pastAnswered: agentID) }
        permission.onEndpointMissing = { [weak self] in self?.reapplyBlockerRules() }
        permission.onOpenTerminal = { [weak self] agentID in self?.activate(agentID: agentID) }
        permission.onReleaseKeyboard = { [weak self] in self?.focusRequest += 1 }
    }

    private func wireMessageCard() {
        messageObservation = message.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        message.onNotice = { [weak self] sentence in self?.showAnswerNotice(sentence) }
        message.onReleaseKeyboard = { [weak self] in self?.focusRequest += 1 }
        message.consumeEscape = { [weak self] in self?.dismissFooterNotice() ?? false }
        message.onSentDirect = { [weak self] agentID, text in self?.recordRoutedNote(agentID: agentID, text: text) }
        message.onDirectSendOutcome = { [weak self] agentID, label, text, outcome in
            self?.handleDirectSendOutcome(agentID: agentID, label: label, text: text, outcome: outcome)
        }
    }

    private func wireBlockerProbe() {
        blockerProbe.currentAgent = { [weak self] id in self?.snapshot?.agents.first { $0.id == id } }
        blockerProbe.onLearned = { [weak self] id, blocker in self?.learnBlocker(blocker, for: id) }
    }

    /// Republishes the hierarchy model (same shape as `answer`/`permission`/`message`), and turns
    /// its attach/detach outcomes into the same footer notice every other row action uses — a
    /// refused/failed attach reads exactly like a failed Done/Close pane, an attach's warning like
    /// a plan-answer warning. The dialogs for a cross-project confirm and an ambiguous-chief picker
    /// (`pendingConfirm`/`pendingChiefPicker`) are drawn by `AgentPanelView` straight off `treeModel`.
    private func wireTreeModel() {
        treeObservation = treeModel.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        treeErrorObservation = treeModel.$errorMessage.compactMap { $0 }.sink { [weak self] message in
            self?.showFailureNotice(.actionFailed(message))
            self?.treeModel.dismissError()
        }
        treeInfoObservation = treeModel.$infoMessage.compactMap { $0 }.sink { [weak self] message in
            self?.showFailureNotice(.warning(message))
            self?.treeModel.dismissInfo()
        }
    }

    /// The probe read a question or box off the pane before the dashboard reported it: show its button now.
    private func learnBlocker(_ blocker: AgentBlocker, for agentID: String) {
        blockerMemory.learn(blocker, for: agentID, now: now())
        if let lastReceived { receive(lastReceived) }
    }

    /// The blockers as the panel shows them: steadied against the dashboard's flapping, and
    /// with Review turned back into Open terminal while the dashboard cannot take approvals.
    private func shownBlockers(_ agents: [AgentSnapshot]) -> [AgentSnapshot] {
        permission.withoutReviewIfEndpointMissing(blockerMemory.steadied(agents, now: now()))
    }

    /// A row's rules changed under it (the dashboard turned out to lack /api/permission).
    private func reapplyBlockerRules() {
        guard let current = snapshot else { return }
        snapshot = current.replacingAgents(permission.withoutReviewIfEndpointMissing(current.agents))
        rebuild()
        selectedAgentID = AgentSelection.reconciled(selectedAgentID, in: presentation.selectableAgentIDs)
        settleRowActions()
    }

    func receive(_ received: StatusSnapshot) {
        lastReceived = received
        let snapshot = received.replacingAgents(shownBlockers(received.agents))
        self.snapshot = snapshot
        treeModel.receive(received)
        // A dead feed shows no agents; that must not read as "they all went away".
        if !snapshot.health.isDown, triage.observe(snapshot.agents) { triageStore.save(triage) }
        rebuild()
        trackNeedsYou()
        selectedAgentID = AgentSelection.reconciled(selectedAgentID, in: presentation.selectableAgentIDs)
        settleRowActions()
        closePeekUnlessStillSelected()
        reconcileAnswerCard()
        // Same care `pruneRoutedNotes`/`blockerProbe.observe` already take below: a dead feed's
        // `agents` is contractually empty (`StatusSnapshot.health.isDown`), so reconciling the tag
        // against it unconditionally would misread "feed blipped" as "the agent left" and clear a
        // perfectly good tag mid-compose. Skip it during an outage; the next healthy reading catches
        // a genuine departure just as well.
        if !snapshot.health.isDown {
            reconcileTag()
            blockerProbe.observe(snapshot.agents)
            pruneRoutedNotes(keeping: snapshot.agents)
        }
    }

    /// New list settings: re-derive the list, keeping the selection while it survives.
    func apply(_ settings: AgentListSettings) {
        guard settings != listSettings else { return }
        listSettings = settings
        rebuild()
        // A setting can reveal agents that were always waiting: not arrivals.
        trackNeedsYou(reportingArrivals: false)
        selectedAgentID = AgentSelection.reconciled(selectedAgentID, in: presentation.selectableAgentIDs)
        closePeekUnlessStillSelected()
        reconcileAnswerCard()
    }

    /// The status feed now comes from another dashboard: forget the old feed's
    /// agents and wait for the new one's first update.
    func useDashboard(address: String) {
        dashboardAddress = address
        snapshot = nil
        lastReceived = nil
        blockerMemory.reset()
        blockerProbe.reset()
        rowActionStates = [:]
        rebuild()
        trackNeedsYou()
        selectedAgentID = nil
        closePeek()
        answer.reset()
        permission.reset()
        message.reset()
        // Any scheduled retry for the old dashboard's agents is left to fire and no-op: its guard
        // (`pendingDirectSends[agentID]?.attempt == attempt - 1`) fails once the dict is cleared.
        pendingDirectSends = [:]
        // A route started against the old dashboard must never be actable once the feed has
        // switched, even if a reply lands with a coincidentally matching epoch and `routingState`
        // back to `.loading` from a route against the new one — so `.loading`/`.confirming` are
        // always wiped here, via the same helper Esc uses.
        _ = cancelRoutingIfActive()
        routingText = ""
        taggedAgentID = nil
    }

    /// Fresh start for each summon: empty search, first row selected.
    func resetForShow() {
        closePeek()
        answer.close()
        permission.close()
        message.close()
        copier.clearFeedback()
        cancelConfirmations()
        // Bumps `routingEpoch` when it walks away from an active route, same as `cancelRoutingIfActive()`
        // (Esc) — otherwise a route started again after this summon reuses the same epoch, and a reply
        // from the abandoned route can pass `finishRouting`'s `epoch == routingEpoch` check and hijack it.
        _ = cancelRoutingIfActive()
        taggedAgentID = nil
        query = ""
        rebuild()
        selectedAgentID = presentation.selectableAgentIDs.first
        focusRequest += 1
    }

    func moveSelection(by step: Int) {
        closePeek()
        answer.close()
        permission.close()
        message.close()
        selectedAgentID = AgentSelection.moved(from: selectedAgentID, by: step, in: presentation.selectableAgentIDs)
    }

    /// Hover: only rows that can be activated take the highlight.
    func select(agentID: String) {
        guard presentation.selectableAgentIDs.contains(agentID) else { return }
        selectedAgentID = agentID
        closePeekUnlessStillSelected()
    }

    /// ↑/↓ from the keyboard: moves the highlight inside an open answer card,
    /// else the selection in the list.
    func moveSelectionOrAnswerHighlight(by step: Int) {
        if answer.isOpen {
            answer.handle(step < 0 ? .up : .down)
        } else if permission.isOpen {
            permission.handle(step < 0 ? .up : .down)
        } else if message.isOpen {
            return   // the text field owns the arrows; from the search box they do nothing
        } else {
            moveSelection(by: step)
        }
    }

    /// Space. Ticks the highlighted option in an open answer card; otherwise
    /// peeks at the selected agent's screen, or closes the peek. Only
    /// with an empty search: otherwise it is a literal space in the query, and
    /// this returns false so the field types it.
    @discardableResult
    func togglePeek() -> Bool {
        if answer.isOpen {
            answer.handle(.space)
            return true
        }
        if permission.isOpen {
            permission.handle(.other)
            return true
        }
        if message.isOpen { return true }
        // While tagged the search box is a compose field: Space must always type a literal space
        // (the box is usually non-empty by then anyway, which already falls through below — but
        // right after tagging, before anything is typed, `query` is still empty and this would
        // otherwise open the pane peek on the very first keystroke).
        guard taggedAgentID == nil, query.isEmpty else { return false }
        if peek != nil {
            closePeek()
        } else {
            openPeekOnSelected()
        }
        return true
    }

    func closePeek() {
        peekLoader.cancel()
        peekMessageLoader.cancel()
        peek = nil
    }

    private func openPeekOnSelected() {
        guard let selectedAgentID,
              let agent = presentation.agents.first(where: { $0.id == selectedAgentID })
        else { return }
        var opened = PanePeek(agentID: agent.id, label: agent.label, projectName: agent.projectName, content: .loading)
        if !agent.host.isHerdr, agent.section != .ended, let sessionId = agent.sessionId {
            openLatestMessagePeek(opened, sessionId: sessionId)
            return
        }
        guard let paneId = agent.paneId, !paneId.isEmpty else {
            opened.content = .unavailable(PanePeek.endedAgentMessage)
            peek = opened
            return
        }
        guard let statusSource else {
            opened.content = .unavailable(PanePeek.noSourceMessage)
            peek = opened
            return
        }
        peek = opened
        peekLoader.load({ await statusSource.paneScreen(paneId: paneId) }) { [weak self] result in
            self?.peek?.content = PanePeek.content(from: result)
        }
    }

    /// A status-only row has no pane to read: the peek is its transcript's latest message.
    private func openLatestMessagePeek(_ opened: PanePeek, sessionId: String) {
        var opened = opened
        opened.content = .loadingLatestMessage
        peek = opened
        let load = loadPeekMessage
        peekMessageLoader.load({ await load(sessionId) }) { [weak self] context in
            guard self?.peek?.agentID == opened.agentID else { return }
            self?.peek?.content = PanePeek.content(fromLatestMessage: context.latestMessage)
        }
    }

    private func closePeekUnlessStillSelected() {
        if peek?.agentID != selectedAgentID { closePeek() }
    }

    /// Enter: presses the highlighted button, or with none highlighted switches to the agent.
    /// A held key (`isKeyRepeat`) does nothing: the press that armed a two-press action (Done, auto mode,
    /// Allow always) must not be confirmed by the same finger still being down.
    func activateSelected(isKeyRepeat: Bool = false) {
        guard !isKeyRepeat else { return }
        if confirmRoutingIfPending() { return }
        if isRoutingInFlight() { return }
        if answer.isOpen {
            answer.handle(.enter)
            return
        }
        if permission.isOpen {
            permission.handle(.enter)
            return
        }
        if message.isOpen {
            message.pressSend()
            return
        }
        if sendToTaggedIfPending() { return }
        guard let selectedAgentID else { return }
        if let highlightedButton {
            press(highlightedButton, on: selectedAgentID)
        } else {
            activate(agentID: selectedAgentID)
        }
    }

    /// The mouse-click path to switching agents (`AgentListView`'s `.onTapGesture`) — a second,
    /// independent entry point from `activateSelected`'s keyboard Return. Ignored while any route
    /// is pending (`.loading`, `.confirming`): the same "nothing else should fire mid-route" rule
    /// `activateSelected` applies to Return must hold here too, or a click bypasses it entirely.
    /// Both states are swallowed the same way (`press(_:on:)`'s card-opening cases apply the
    /// identical guard) rather than letting a click confirm a route meant for the row Jev picked,
    /// not the row the user happened to click — confirming stays Return's job alone.
    func activate(agentID: String) {
        guard routingState == nil else { return }
        guard presentation.selectableAgentIDs.contains(agentID),
              let agent = presentation.agents.first(where: { $0.id == agentID })
        else { return }
        onActivate(agent)
    }

    // MARK: - Row buttons (Done / Park / Unpark / Close pane)

    private var selectedAgent: AgentSnapshot? {
        selectedAgentID.flatMap { id in presentation.agents.first { $0.id == id } }
    }

    /// ←/→: moves the highlight across the selected row's buttons. Only with an
    /// empty search (otherwise the arrows move the text caret, and this returns
    /// false so the field handles them) - the same rule as Space-to-peek.
    /// While peeking the arrows do nothing. Left off the first button
    /// un-highlights it and cancels a pending confirmation.
    @discardableResult
    func moveButtonHighlight(by step: Int) -> Bool {
        guard query.isEmpty else { return false }
        if permission.isOpen {
            permission.handle(.other)   // a stray key never carries a pending "Allow always" over
            return true
        }
        guard !answer.isOpen, !message.isOpen else { return true }
        guard peek == nil, let agent = selectedAgent else { return true }
        let previous = highlightedButton
        highlightedButton = RowButtonHighlight.moved(from: previous, by: step, in: usableButtons(for: agent))
        if previous != nil, highlightedButton == nil { cancelConfirmation(for: agent.id) }
        return true
    }

    /// Esc: backs out of the button level (un-highlights, cancels a pending
    /// confirmation). False when there was nothing to back out of, so Esc
    /// goes on to close the peek / panel.
    func backOutOfButtons() -> Bool {
        if cancelRoutingIfActive() { return true }
        // A card takes precedence over an (invisible, background) tag: `press(_:on:)` already
        // clears the tag the moment a card opens, but this ordering is the same belt-and-suspenders
        // rule `activateSelected()` already applies (its card checks precede `sendToTaggedIfPending()`
        // too) — Esc must close what the user is actually looking at.
        if answer.isOpen {
            answer.handle(.escape)   // to the list; ignored while an answer is being sent
            return true
        }
        if permission.isOpen {
            permission.handle(.escape)   // cancels a pending "Allow always", else back to the list
            return true
        }
        if message.isOpen {
            message.handleEscape()   // back to the list; ignored while the message is being sent
            return true
        }
        if cancelTagIfActive() { return true }
        guard let selectedAgentID else { return false }
        let confirming = isConfirming(selectedAgentID)
        guard highlightedButton != nil || confirming else { return false }
        highlightedButton = nil
        cancelConfirmation(for: selectedAgentID)
        return true
    }

    /// A press on `button` of agent `agentID` (mouse, or Enter on the highlight).
    /// Park / Unpark act at once; Done / Close pane ask the dashboard, and the
    /// returned task ends when it has answered (tests await it).
    @discardableResult
    func press(_ button: RowButton, on agentID: String) -> Task<Void, Never>? {
        guard let agent = presentation.agents.first(where: { $0.id == agentID }),
              isPressable(button, on: agent) else { return nil }
        switch RowActionMachine.plan(pressing: button, current: rowActionStates[agentID]) {
        case .ignore:
            return nil
        case .park:
            setParked(true, agentID: agentID)
            return nil
        case .unpark:
            setParked(false, agentID: agentID)
            return nil
        case .openAnswer:
            guard routingState == nil else { return nil }   // see `activate(agentID:)`: nothing else fires mid-route
            selectedAgentID = agentID
            closePeek()
            taggedAgentID = nil   // a card taking over the keyboard must not leave a tag lingering behind it
            permission.close()
            message.close()
            answer.open(agent)
            return nil
        case .openReview:
            guard routingState == nil else { return nil }
            selectedAgentID = agentID
            closePeek()
            taggedAgentID = nil
            answer.close()
            message.close()
            permission.open(agent)
            return nil
        case .openMessage:
            guard routingState == nil else { return nil }
            selectedAgentID = agentID
            closePeek()
            taggedAgentID = nil
            answer.close()
            permission.close()
            message.open(agent)
            return nil
        case .openTerminal:
            onActivate(agent)
            return nil
        case .sendQuickCommand(let text):
            sendDirectMessage(to: agent, text: text)
            return nil
        case .send(let kind, let confirmed):
            return send(kind, confirmed: confirmed, button: button, agent: agent)
        case .reportToNearestChief:
            treeModel.selectedNodeID = agentID   // menu press may not be on the currently-selected row
            treeModel.indentSelected()
            return nil
        case .stopReporting:
            treeModel.selectedNodeID = agentID
            treeModel.outdentSelected()
            return nil
        }
    }

    /// `button` is currently something `agent`'s row would let the user act on right now —
    /// whichever surface it lives on (its capsule strip or the ⋯ menu, `TreeRowActions.isPressable`) —
    /// and the row is not mid-flight on some other send (no actions while a spinner or a
    /// "Message sent" label is showing in their place).
    private func isPressable(_ button: RowButton, on agent: AgentSnapshot) -> Bool {
        guard sendingLabel(for: agent) == nil, sentLabel(for: agent) == nil else { return false }
        return TreeRowActions.isPressable(button, on: agent, tree: treeModel.tree)
    }

    private func setParked(_ isParked: Bool, agentID: String) {
        let following = AgentSelection.neighbour(of: agentID, in: presentation.selectableAgentIDs)
        rowActionStates[agentID] = nil
        if isParked { triage.park(agentID) } else { triage.unpark(agentID) }
        triageStore.save(triage)
        rebuild()
        trackNeedsYou()
        // A parked row leaves the top of the list: carry on with the next one.
        // An unparked one stays selected, wherever it lands.
        selectedAgentID = AgentSelection.reconciled(isParked ? following : agentID, in: presentation.selectableAgentIDs)
        highlightedButton = nil
    }

    private func send(_ kind: SessionActionKind, confirmed: Bool, button: RowButton, agent: AgentSnapshot) -> Task<Void, Never>? {
        guard let statusSource, let rowId = agent.rowId else {
            showFailureNotice(.actionFailed(RowActionText.failureNotice(kind: kind, message: PanePeek.noSourceMessage)))
            return nil
        }
        rowActionStates[agent.id] = .busy(button)
        return Task { [weak self] in
            let outcome = await statusSource.perform(kind, rowId: rowId, confirmed: confirmed)
            self?.finishPress(of: button, kind: kind, agentID: agent.id, outcome: outcome)
        }
    }

    private func finishPress(of button: RowButton, kind: SessionActionKind, agentID: String, outcome: SessionActionOutcome) {
        let result = RowActionMachine.state(after: outcome, pressing: button)
        rowActionStates[agentID] = result.state
        if let failure = result.failure {
            showFailureNotice(.actionFailed(RowActionText.failureNotice(kind: kind, message: failure)))
        }
        if case .completed = result.state {
            expireCompletedState(of: agentID, after: completedHoldSeconds)
            // Done: the agent is finished with, so carry on with the next row.
            if button == .done, selectedAgentID == agentID {
                let following = AgentSelection.neighbour(of: agentID, in: presentation.selectableAgentIDs)
                selectedAgentID = following ?? selectedAgentID
            }
        }
    }

    /// After an answered question: on to the next row that needs the user.
    private func advanceSelection(pastAnswered agentID: String) {
        let needsYouIDs = presentation.agents.filter { $0.section == .needsYou && $0.canFocus }.map(\.id)
        if let following = AgentSelection.neighbour(of: agentID, in: needsYouIDs) { selectedAgentID = following }
    }

    /// Keeps an open answer card true to the latest status (over every agent the
    /// user could see, not just the ones the search leaves).
    private func reconcileAnswerCard() {
        let shown = snapshot.map { AgentListBuilder.shownAgents(in: $0, settings: listSettings, triage: triage) } ?? []
        answer.reconcile(with: shown)
        permission.reconcile(with: shown)
        message.reconcile(with: shown)
    }

    /// A "completed" row waits for the next status update to show the result;
    /// if none does (a lagging feed), it stops waiting rather than stay stuck.
    private func expireCompletedState(of agentID: String, after seconds: TimeInterval) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard case .completed? = self?.rowActionStates[agentID] else { return }
            self?.rowActionStates[agentID] = nil
        }
    }

    /// After a refresh: forget states of rows that are gone, and completed ones
    /// whose button is gone too (the result has arrived); drop a highlight
    /// on a button the row no longer has.
    private func settleRowActions() {
        let agentsByID = Dictionary(presentation.agents.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        rowActionStates = rowActionStates.filter { id, state in
            guard let agent = agentsByID[id] else { return false }
            // Done/Close pane live in the ⋯ menu now, not `usableButtons` — `isPressable` still
            // finds them there, so "still completed" keeps meaning "the dashboard hasn't caught up yet".
            if case .completed(let button) = state { return RowButtons.isPressable(button, on: agent) }
            return true
        }
        if let agent = selectedAgent {
            highlightedButton = RowButtonHighlight.reconciled(highlightedButton, in: usableButtons(for: agent))
        } else {
            highlightedButton = nil
        }
    }

    private func isConfirming(_ agentID: String) -> Bool {
        if case .confirming? = rowActionStates[agentID] { return true }
        return false
    }

    private func cancelConfirmation(for agentID: String) {
        if isConfirming(agentID) { rowActionStates[agentID] = nil }
    }

    private func cancelConfirmations() {
        rowActionStates = rowActionStates.filter { _, state in
            if case .confirming = state { return false }
            return true
        }
    }

    /// A switch worked: count it toward the agent's ranking.
    func recordSwitch(to agentID: String) {
        frecency = FrecencyStore.recordingVisit(to: agentID, in: frecency, now: now())
        store.save(frecency)
        rebuild()
    }

    /// A switch failed: show why, in the panel, until the user closes it. Not counted
    /// toward ranking (a dead pane must not float to the top).
    func reportSwitchFailure(_ message: String) {
        showFailureNotice(.switchFailed(message))
    }

    /// The buttons the keyboard and mouse can use on `agent`'s row: none while its answer or decision is on its way.
    private func usableButtons(for agent: AgentSnapshot) -> [RowButton] {
        guard sendingLabel(for: agent) == nil, sentLabel(for: agent) == nil else { return [] }
        return TreeRowActions.availableButtons(for: agent, tree: treeModel.tree).filter(\.isEnabled).map(\.button)
    }

    /// What the row says in place of its buttons while an answer or decision is on its way; nil when none is.
    /// Covers the gap between a headless send's retries too (`message.sendingLabel` only knows
    /// about the attempt actually in flight, not the backoff between them) so the row doesn't
    /// flicker back to its normal buttons for a few seconds between tries.
    func sendingLabel(for agent: AgentSnapshot) -> String? {
        if answer.isAwaiting(agent) { return "Sending answer…" }
        if let label = permission.sendingLabel(for: agent) ?? message.sendingLabel(for: agent) { return label }
        return pendingDirectSends[agent.id] != nil ? MessageCardModel.sendingLabel : nil
    }

    /// What the row says for a few seconds after a message to it went ("Message sent" / "Message queued").
    func sentLabel(for agent: AgentSnapshot) -> String? {
        message.sentLabel(for: agent)
    }

    // MARK: - Copy

    /// The row's copy icon.
    func copyIdentity(of agent: AgentSnapshot) {
        copier.copy(agent.identityText, for: agent.id)
    }

    /// The card's copy button or ⌘C. False when no card is open (the key is then left alone).
    @discardableResult
    func copyOpenCardIdentity() -> Bool {
        if let card = answer.card {
            copier.copy(card.identityText, for: card.agentID)
        } else if let card = permission.card {
            copier.copy(card.identityText, for: card.agentID)
        } else if let card = message.card {
            copier.copy(card.identityText, for: card.agentID)
        } else {
            return false
        }
        return true
    }

    /// A digit typed while a card is open: picks that option on it (the search box types nothing).
    func handleCardDigit(_ number: Int) {
        if answer.isOpen { answer.handle(.digit(number)) }
        else if permission.isOpen { permission.handle(.digit(number)) }
    }

    /// Any other character typed while a card is open: dropped (it still cancels a pending "Allow always").
    func handleCardStrayKey() {
        if permission.isOpen { permission.handle(.other) }
    }

    private func showAnswerNotice(_ sentence: String) {
        guard !isOpeningCardForCorner else { return }
        showFailureNotice(.actionFailed(sentence))
    }

    /// A failure to show in the panel: it stays, whether or not the panel is on screen, until
    /// the user dismisses it or a newer failure replaces it.
    private func showFailureNotice(_ notice: PanelFooterNotice) {
        failureNotice = notice
        refreshFooterNotice()
    }

    /// The global shortcut could not be registered; shown until the app quits.
    func reportHotkeyIssue(_ message: String?) {
        hotkeyIssue = message
        refreshFooterNotice()
    }

    /// The ✕ / Esc: closes the failure notice. False when there is none, so Esc goes on to
    /// its other jobs (the shortcut warning is not closable; it goes when the shortcut works).
    @discardableResult
    func dismissFooterNotice() -> Bool {
        guard failureNotice != nil else { return false }
        failureNotice = nil
        refreshFooterNotice()
        return true
    }

    private func refreshFooterNotice() {
        footerNotice = PanelFooterNotice.resolve(failure: failureNotice, hotkeyIssue: hotkeyIssue)
    }

    /// What the corner tab says when the pointer rests in the corner.
    func needsYouSummary() -> CornerTabContent {
        CornerTabContent.summary(of: AgentListBuilder.needsYouAgents(snapshot: snapshot, settings: listSettings, triage: triage))
    }

    // MARK: - Corner tab card

    private var isOpeningCardForCorner = false

    /// The corner tab found `agentID` to be the sole agent blocked with something answerable: opens
    /// its card exactly as the row's Answer/Review press would, so the corner shows the live card
    /// (form batches, plan feedback, everything). Already open for that agent (from here or from an
    /// earlier row press) is a no-op that reports success, so an in-progress draft or send is never
    /// reset. False when there is nothing to show (the agent is gone, its answer is in flight, no
    /// pane): the corner then shows its plain pill instead of an empty card. Looks in every shown
    /// agent, not just the searched list, so a leftover search never hides the blocked agent.
    @discardableResult
    func openCardForCorner(agentID: String) -> Bool {
        // The corner retries on its own (readings, card changes); "already answered" and the like are
        // not news to the user then, so a failed attempt stays silent.
        isOpeningCardForCorner = true
        defer { isOpeningCardForCorner = false }
        if answer.card?.agentID == agentID || permission.card?.agentID == agentID { return true }
        guard let snapshot,
              let agent = AgentListBuilder.shownAgents(in: snapshot, settings: listSettings, triage: triage)
                .first(where: { $0.id == agentID })
        else { return false }
        switch agent.blockedOnYou {
        case .question?:
            guard answer.open(agent) else { return false }
            message.close()
            permission.close()
            return true
        case .permissionReview?:
            guard permission.open(agent) else { return false }
            message.close()
            answer.close()
            return true
        case .questionLoading?, .questionNotAnswerable?, .permission?, nil:
            return false
        }
    }

    /// The answer the user just sent for `agentID` is still on its way (or waiting for the dashboard to
    /// catch up): the corner puts itself away instead of showing a pill about it.
    func isAnswerBeingSent(agentID: String) -> Bool {
        guard let snapshot,
              let agent = AgentListBuilder.shownAgents(in: snapshot, settings: listSettings, triage: triage)
                .first(where: { $0.id == agentID })
        else { return false }
        return answer.isAwaiting(agent)
    }

    /// The corner left card mode (a second agent became blocked, the sole one was dealt with, or
    /// the setting/panel took over): closes whichever card it had opened. Harmless if the send that
    /// resolved it already closed the card itself.
    func closeCardOpenedForCorner() {
        answer.close()
        permission.close()
    }

    /// Compares Needs you with the previous reading and reports newcomers.
    private func trackNeedsYou(reportingArrivals: Bool = true) {
        let needsYou = AgentListBuilder.needsYouAgents(snapshot: snapshot, settings: listSettings, triage: triage)
        let arrivals = arrivalDetector.observe(needsYou)
        if reportingArrivals, let needsYou, let content = CornerTabContent.forArrivals(arrivals, among: needsYou) {
            onNeedsYouArrival(content)
        }
        onNeedsYouReading(reportingArrivals ? arrivals : [], needsYou)
    }

    private func rebuild() {
        presentation = AgentListBuilder.presentation(
            snapshot: snapshot, query: query, frecency: frecency, now: now(), settings: listSettings, triage: triage
        )
    }
}
