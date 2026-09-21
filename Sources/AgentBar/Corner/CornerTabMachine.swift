import Foundation

/// How long the corner tab waits and stays.
struct CornerTabTiming: Equatable, Sendable {
    /// How long an arrival's tab stays when the pointer is not on it.
    var visibleSeconds: TimeInterval
    /// How long the pointer must rest in the corner before the tab slides in, so passing
    /// through the corner (or dragging something past it) shows nothing.
    var hoverDwellSeconds: TimeInterval
    /// How long the tab stays after the pointer leaves it and the corner.
    var leaveGraceSeconds: TimeInterval

    static let standard = CornerTabTiming(visibleSeconds: 5, hoverDwellSeconds: 0.3, leaveGraceSeconds: 0.7)
}

enum CornerTabEvent: Equatable, Sendable {
    /// An agent entered Needs you.
    case arrival(CornerTabContent)
    /// Every reading of Needs you (`nothingNeedsYou` when the feed is down): how many are blocked
    /// on the user now, and whether one just became blocked (a late classification, or a new question).
    case needsYouChanged(CornerTabContent, hasNewBlocker: Bool)
    /// The pointer is now over (or no longer over) the bottom-right corner or the tab.
    case mouse(isOverCornerOrTab: Bool)
    case tabClicked
    /// The ✕ on the tab or card: put it away without opening the panel or answering. `cardAgentID` is
    /// the agent whose card was showing (nil for the plain pill).
    case dismissed(cardAgentID: String?)
    /// The main panel appeared or disappeared, however that happened.
    case panelVisibility(Bool)
    /// The Settings toggle.
    case enabled(Bool)
    /// The deadline in `nextDeadline` has come.
    case deadlineReached
}

/// What the window layer must do as a result.
enum CornerTabEffect: Equatable, Sendable {
    /// Slide the tab in with this content (an arrival).
    case showTab(CornerTabContent)
    /// Slide the tab in with the current Needs-you summary (the pointer rested in the corner).
    case showSummaryTab
    case updateTab(CornerTabContent)
    /// Slide in the sole blocked agent's live card in place of the tab (`content.soleCardableAgentID`).
    case showCard(agentID: String)
    /// The card is already showing; only its identity may have changed (a different sole agent).
    case updateCard(agentID: String)
    case slideTabOut
    case removeTabNow
    case openPanel
}

/// The corner tab's life cycle, with no clock or windows of its own: every event carries
/// `now`, and the machine names the next `nextDeadline` for the host to wake it at. Pure.
///
///     idle --arrival--> tab                       (stays while the pointer is on it)
///     idle --an agent becomes blocked--> tab
///     tab --deadline--> idle                      (slides out; never while an agent is blocked)
///     idle --pointer in the corner--> dwelling --rests a moment--> tab
///     dwelling --pointer leaves--> idle
///     tab --pointer leaves the tab and corner--> tab (hides after a short grace)
///     tab --click--> idle                         (opens the panel like the shortcut)
///     tab --✕--> idle                             (slides out; the blocker stays in Needs you, not re-announced)
///
/// Hovering never opens the panel; only a click does. Nothing shows while the panel is
/// open or the setting is off.
///
/// **Sticky**: while any agent in Needs you is blocked on the user, the tab has no timer and no
/// leave-grace: it stays until the panel opens, it is clicked, the setting goes off, or the last
/// blocked agent is dealt with (then the usual short grace). An arrival tab shown as generic
/// becomes sticky the moment its agent turns out to be blocked; one that already slid out comes
/// back, once per blocker.
///
/// **Card mode**: whenever exactly one agent is blocked with something AgentBar can render
/// (`content.soleCardableAgentID`), `showTab`/`updateTab` are replaced by `showCard`/`updateCard`:
/// the corner shows that agent's live Answer/Review card instead of the pill. Two or more blocked,
/// or the one blocker having no card (`questionLoading`/`questionNotAnswerable`/plain `permission`),
/// falls back to the plain pill. Every other rule (sticky, timers, click) is unchanged — only what
/// is drawn differs.
struct CornerTabMachine: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case idle
        /// The pointer is in the corner; the tab slides in at `showAt` if it is still there.
        case dwelling(showAt: Date)
        /// Showing. `hideAt` is nil while the pointer is on the tab or in the corner.
        case tab(hideAt: Date?)
    }

    private(set) var phase: Phase = .idle
    private var isEnabled: Bool
    private var isPanelVisible = false
    private var pointerIsOver = false
    /// How many agents in Needs you are blocked on the user, as of the latest reading.
    private var blockedCount = 0
    /// The agent whose card the user dismissed: it stays out of card mode (an unrelated arrival shows the
    /// plain pill) until it gets a new blocker, nothing is blocked, or the pointer summons the corner.
    private var dismissedCardAgentID: String?
    /// What the showing tab says, when the machine knows (not after a hover tab, whose text the host reads).
    private var shownContent: CornerTabContent?
    private let timing: CornerTabTiming

    init(timing: CornerTabTiming = .standard, isEnabled: Bool = true) {
        self.timing = timing
        self.isEnabled = isEnabled
    }

    var nextDeadline: Date? {
        switch phase {
        case .idle: nil
        case .dwelling(let showAt): showAt
        case .tab(let hideAt): hideAt
        }
    }

    /// Whether the host should follow the pointer's moves at all (to notice it reaching the corner).
    var wantsCornerWatch: Bool { isEnabled && !isPanelVisible }

    /// Whether the host should poll the pointer: while the tab is up, the pointer over it
    /// generates no moves the host could observe.
    var wantsMousePolling: Bool {
        if case .tab = phase { return true }
        return false
    }

    mutating func handle(_ event: CornerTabEvent, now: Date) -> [CornerTabEffect] {
        switch event {
        case .arrival(let content): return arrive(content, now: now)
        case .needsYouChanged(let content, let hasNewBlocker): return needsYouChanged(content, hasNewBlocker: hasNewBlocker, now: now)
        case .mouse(let isOver): return pointerMoved(isOver: isOver, now: now)
        case .tabClicked: return clicked()
        case .dismissed(let cardAgentID): return dismissed(cardAgentID: cardAgentID)
        case .panelVisibility(let isVisible): return panelVisibilityChanged(isVisible)
        case .enabled(let isEnabled): return setEnabled(isEnabled)
        case .deadlineReached: return deadlineReached(now: now)
        }
    }

    private var isSticky: Bool { blockedCount > 0 }

    private mutating func arrive(_ content: CornerTabContent, now: Date) -> [CornerTabEffect] {
        blockedCount = content.blockedCount
        if blockedCount == 0 { dismissedCardAgentID = nil }
        guard isEnabled, !isPanelVisible else { return [] }
        let hideAt = pointerIsOver || isSticky ? nil : now.addingTimeInterval(timing.visibleSeconds)
        shownContent = content
        switch phase {
        case .idle, .dwelling:
            phase = .tab(hideAt: hideAt)
            return [showEffect(for: content)]
        case .tab:
            phase = .tab(hideAt: hideAt)
            return [updateEffect(for: content)]
        }
    }

    private mutating func needsYouChanged(_ content: CornerTabContent, hasNewBlocker: Bool, now: Date) -> [CornerTabEffect] {
        let wasSticky = isSticky
        blockedCount = content.blockedCount
        if hasNewBlocker || blockedCount == 0 { dismissedCardAgentID = nil }
        guard isEnabled, !isPanelVisible else { return [] }
        switch phase {
        case .idle, .dwelling:
            guard hasNewBlocker, isSticky else { return [] }
            phase = .tab(hideAt: nil)
            shownContent = content
            return [showEffect(for: content)]
        case .tab:
            if isSticky {
                phase = .tab(hideAt: nil)
            } else if wasSticky {
                // The last blocked agent was dealt with: leave after the usual short grace.
                phase = .tab(hideAt: pointerIsOver ? nil : now.addingTimeInterval(timing.leaveGraceSeconds))
            } else {
                return []   // a generic tab keeps its own timer and words
            }
            guard content != shownContent else { return [] }
            shownContent = content
            return [updateEffect(for: content)]
        }
    }

    /// The sole blocked agent's card in place of the tab, when there is one to show.
    private func showEffect(for content: CornerTabContent) -> CornerTabEffect {
        soleCardableAgentID(of: content).map(CornerTabEffect.showCard(agentID:)) ?? .showTab(content)
    }

    private func updateEffect(for content: CornerTabContent) -> CornerTabEffect {
        soleCardableAgentID(of: content).map(CornerTabEffect.updateCard(agentID:)) ?? .updateTab(content)
    }

    private func soleCardableAgentID(of content: CornerTabContent) -> String? {
        content.soleCardableAgentID.flatMap { $0 == dismissedCardAgentID ? nil : $0 }
    }

    private mutating func pointerMoved(isOver: Bool, now: Date) -> [CornerTabEffect] {
        pointerIsOver = isOver
        switch phase {
        case .idle:
            guard isOver, isEnabled, !isPanelVisible else { return [] }
            phase = .dwelling(showAt: now.addingTimeInterval(timing.hoverDwellSeconds))
        case .dwelling:
            if !isOver { phase = .idle }
        case .tab(let hideAt):
            if isOver {
                phase = .tab(hideAt: nil)
            } else if hideAt == nil, !isSticky {
                phase = .tab(hideAt: now.addingTimeInterval(timing.leaveGraceSeconds))
            }
        }
        return []
    }

    private mutating func clicked() -> [CornerTabEffect] {
        guard case .tab = phase else { return [] }
        phase = .idle
        return [.removeTabNow, .openPanel]
    }

    /// Put away for now. Idle again, so a blocker already announced does not bring it back (the
    /// `hasNewBlocker` gate); a new one, or the pointer resting in the corner, does.
    private mutating func dismissed(cardAgentID: String?) -> [CornerTabEffect] {
        guard case .tab = phase else { return [] }
        phase = .idle
        dismissedCardAgentID = cardAgentID
        return [.slideTabOut]
    }

    private mutating func panelVisibilityChanged(_ isVisible: Bool) -> [CornerTabEffect] {
        isPanelVisible = isVisible
        // The host stops following the pointer while the panel is open, so what it last reported (on the
        // tab, in the corner) goes stale; the next sample after the panel closes says where it really is.
        pointerIsOver = false
        guard isVisible else { return [] }
        let wasShowing = wantsMousePolling
        phase = .idle
        return wasShowing ? [.removeTabNow] : []
    }

    private mutating func setEnabled(_ enabled: Bool) -> [CornerTabEffect] {
        isEnabled = enabled
        guard !enabled else { return [] }
        let wasShowing = wantsMousePolling
        phase = .idle
        return wasShowing ? [.slideTabOut] : []
    }

    private mutating func deadlineReached(now: Date) -> [CornerTabEffect] {
        switch phase {
        case .dwelling(let showAt) where now >= showAt:
            phase = .tab(hideAt: pointerIsOver || isSticky ? nil : now.addingTimeInterval(timing.visibleSeconds))
            shownContent = nil
            dismissedCardAgentID = nil   // the user asked for it by resting the pointer here
            return [.showSummaryTab]
        case .tab(let hideAt?) where now >= hideAt:
            phase = .idle
            return [.slideTabOut]
        default:
            return []
        }
    }
}
