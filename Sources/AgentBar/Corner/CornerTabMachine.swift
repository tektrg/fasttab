import Foundation

/// How long the corner tab stays, and how long the hover-opened panel lingers
/// after the mouse leaves.
struct CornerTabTiming: Equatable, Sendable {
    var visibleSeconds: TimeInterval
    var hoverGraceSeconds: TimeInterval

    static let standard = CornerTabTiming(visibleSeconds: 5, hoverGraceSeconds: 0.5)
}

enum CornerTabEvent: Equatable, Sendable {
    /// An agent entered Needs you.
    case arrival(CornerTabContent)
    /// The mouse is now over (or no longer over) the tab, or the panel it opened.
    case mouse(isOverTabOrPanel: Bool)
    /// The user pressed a key in the hover-opened panel.
    case keyPressed
    case tabClicked
    /// The main panel appeared or disappeared, however that happened.
    case panelVisibility(Bool)
    /// The Settings toggle.
    case enabled(Bool)
    /// The deadline in `nextDeadline` has come.
    case deadlineReached
}

/// What the window layer must do as a result.
enum CornerTabEffect: Equatable, Sendable {
    case showTab(CornerTabContent)
    case updateTab(CornerTabContent)
    case slideTabOut
    case removeTabNow
    case openPanel
    case closePanel
}

/// The corner tab's life cycle, with no clock or windows of its own: every
/// event carries `now`, and the machine names the next `nextDeadline` for the
/// host to wake it at. Pure.
///
///     idle --arrival--> tab --deadline--> idle            (slides out)
///     tab --mouse enters (after it was seen outside)--> hoverOpen   (opens the panel)
///     tab --click--> idle                                  (opens the panel)
///     hoverOpen --mouse leaves--> grace --deadline--> idle (closes the panel)
///     hoverOpen --key press--> idle                        (a normally summoned panel)
struct CornerTabMachine: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case idle
        /// Showing. `mouseHasLeft`: the mouse was seen outside the tab since
        /// it appeared, so a resting cursor does not open the panel by itself.
        case tab(hideAt: Date, mouseHasLeft: Bool)
        /// The panel was opened by hovering; `closeAt` is set while the mouse is away.
        case hoverOpen(closeAt: Date?)
    }

    private(set) var phase: Phase = .idle
    private var isEnabled: Bool
    private var isPanelVisible = false
    private let timing: CornerTabTiming

    init(timing: CornerTabTiming = .standard, isEnabled: Bool = true) {
        self.timing = timing
        self.isEnabled = isEnabled
    }

    var nextDeadline: Date? {
        switch phase {
        case .idle: nil
        case .tab(let hideAt, _): hideAt
        case .hoverOpen(let closeAt): closeAt
        }
    }

    /// Whether the host should be watching the mouse.
    var wantsMouseUpdates: Bool { phase != .idle }

    /// Whether the host should be watching for key presses.
    var wantsKeyPresses: Bool {
        if case .hoverOpen = phase { return true }
        return false
    }

    mutating func handle(_ event: CornerTabEvent, now: Date) -> [CornerTabEffect] {
        switch event {
        case .arrival(let content): return arrive(content, now: now)
        case .mouse(let isOver): return mouseMoved(isOver: isOver, now: now)
        case .keyPressed: return keyPressed()
        case .tabClicked: return openFromTab(mouseHasLeft: false)
        case .panelVisibility(let isVisible): return panelVisibilityChanged(isVisible)
        case .enabled(let isEnabled): return setEnabled(isEnabled)
        case .deadlineReached: return deadlineReached(now: now)
        }
    }

    private mutating func arrive(_ content: CornerTabContent, now: Date) -> [CornerTabEffect] {
        guard isEnabled, !isPanelVisible else { return [] }
        let hideAt = now.addingTimeInterval(timing.visibleSeconds)
        switch phase {
        case .idle:
            phase = .tab(hideAt: hideAt, mouseHasLeft: false)
            return [.showTab(content)]
        case .tab(_, let mouseHasLeft):
            phase = .tab(hideAt: hideAt, mouseHasLeft: mouseHasLeft)
            return [.updateTab(content)]
        case .hoverOpen:
            return []
        }
    }

    private mutating func mouseMoved(isOver: Bool, now: Date) -> [CornerTabEffect] {
        switch phase {
        case .idle:
            return []
        case .tab(let hideAt, let mouseHasLeft):
            if !isOver {
                phase = .tab(hideAt: hideAt, mouseHasLeft: true)
                return []
            }
            return mouseHasLeft ? openFromTab(mouseHasLeft: true) : []
        case .hoverOpen(let closeAt):
            if isOver {
                phase = .hoverOpen(closeAt: nil)
            } else if closeAt == nil {
                phase = .hoverOpen(closeAt: now.addingTimeInterval(timing.hoverGraceSeconds))
            }
            return []
        }
    }

    /// Hover opens the panel and stays in charge of closing it; a click opens
    /// it as if summoned.
    private mutating func openFromTab(mouseHasLeft: Bool) -> [CornerTabEffect] {
        guard case .tab = phase else { return [] }
        phase = mouseHasLeft ? .hoverOpen(closeAt: nil) : .idle
        return [.removeTabNow, .openPanel]
    }

    private mutating func keyPressed() -> [CornerTabEffect] {
        if case .hoverOpen = phase { phase = .idle }
        return []
    }

    private mutating func panelVisibilityChanged(_ isVisible: Bool) -> [CornerTabEffect] {
        isPanelVisible = isVisible
        switch phase {
        case .tab where isVisible:
            phase = .idle
            return [.removeTabNow]
        case .hoverOpen where !isVisible:
            phase = .idle
            return []
        default:
            return []
        }
    }

    private mutating func setEnabled(_ enabled: Bool) -> [CornerTabEffect] {
        isEnabled = enabled
        guard !enabled, case .tab = phase else { return [] }
        phase = .idle
        return [.slideTabOut]
    }

    private mutating func deadlineReached(now: Date) -> [CornerTabEffect] {
        switch phase {
        case .tab(let hideAt, _) where now >= hideAt:
            phase = .idle
            return [.slideTabOut]
        case .hoverOpen(let closeAt?) where now >= closeAt:
            phase = .idle
            return [.closePanel]
        default:
            return []
        }
    }
}
