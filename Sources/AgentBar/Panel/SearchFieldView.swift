import SwiftUI

/// Search box at the top of the panel; grabs keyboard focus on every show.
/// ←/→ walk the selected row's buttons, but only while the box is empty (with
/// text in it they move the caret); Enter presses the highlighted button, else
/// switches to the agent. With a card (answer or permission) open the keys drive the card.
/// Tab-tagged (`AgentPanelModel.taggedAgentID`): the icon becomes a message glyph with a `TagChipView`
/// naming the target (its ✕ untags), on its own row above the field rather than sharing the field's
/// row — a long agent name would otherwise squeeze the field down to a fraction of its usual width,
/// under-reserving height for the typed message and clipping it (`AgentPanelMetrics.tagRowHeight`).
/// The field's placeholder also names the target — the box IS the compose field then, and
/// `AgentPanelView` hides the list below it (nothing left to pick from once a target is already chosen).
struct SearchFieldView: View {
    /// Posted only on a genuine mouse click into the field — never on the auto-focus in `.onAppear`
    /// or the keyboard-reclaim in `.onChange(of: model.focusRequest)`, both of which are passive and
    /// must not activate AgentBar (`TextInputActivation`, `AGENTS.md` gotcha 12: a plain ⌥Tab cycle,
    /// or a card closing, must never steal the front from the app the user is switching away from).
    /// A deliberate click is a different signal: the user is about to dictate into search, so it's
    /// safe to also activate here.
    static let didReceiveClickNotification = Notification.Name("AgentBar.SearchField.didReceiveClick")

    @ObservedObject var model: AgentPanelModel
    let onClose: () -> Void
    @FocusState private var isFocused: Bool

    /// How many lines the field should reserve for the current text (see `AgentPanelMetrics`);
    /// 1 for a plain search, more once a longer message to route is typed or pasted in.
    private var lineCount: Int { AgentPanelMetrics.searchFieldLineCount(for: model.query) }

    /// The real root cause of AGENTS.md gotcha 18 (Tab-tagging dropped keyboard focus): this used to
    /// be `if tagged { ...; field } else { HStack { icon; field } }` — TWO textually different call
    /// sites for `field`, one per branch. SwiftUI identifies a view by its position in the body's
    /// static structure, not by comparing values, so switching branches was a guaranteed identity
    /// loss for `field` — the old one is torn down, a new one built, and anything tracking a
    /// "previous" value for it (`.onChange`) restarts blind. Fixed by giving `field` exactly ONE call
    /// site, in a row that is unconditionally present in the body either way; only the LEADING
    /// content of that row (an optional icon) and an optional sibling row above it vary. Per
    /// SwiftUI's `ViewBuilder`, sibling statements in the same container each get their own stable
    /// tree slot, so an optional sibling appearing/disappearing does not perturb another statement's
    /// identity — unlike swapping which branch a shared call site lives in. Any future change to this
    /// body must keep `field` at its one call site, or this bug returns.
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let taggedLabel = model.taggedAgentLabel {
                HStack(spacing: 10) {
                    // Tagged: the icon reads as "you're messaging someone", the same way the magnifying
                    // glass reads as "you're searching" the rest of the time.
                    Image(systemName: "message.fill")
                        .foregroundStyle(.secondary)
                    TagChipView(label: taggedLabel, onRemove: model.removeTag)
                }
                .frame(height: AgentPanelMetrics.tagRowHeight)
                // Order matters: sized first, THEN padded, so this adds height on top of
                // `tagRowHeight` (matching the extra budgeted in `AgentPanelMetrics.height(for:...)`)
                // instead of squeezing the already-sized row down to fit inside it.
                .padding(.top, AgentPanelMetrics.tagChipTopPadding)
            }
            // Unconditionally present either way — `field`'s one and only call site (see doc comment
            // above). Untagged: the magnifying glass shares this row with it, same as always. Tagged:
            // the icon has already been drawn in the chip row above, so this row is the field alone,
            // at its full width regardless of how long the tagged agent's name is.
            HStack(spacing: 10) {
                if model.taggedAgentLabel == nil {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                }
                field
            }
            .frame(height: fieldRowHeight)
            if let routingState = model.routingState {
                routingRow(for: routingState)
                    .padding(.leading, 28)
                    .frame(height: AgentPanelMetrics.routingRowHeight, alignment: .leading)
            }
        }
        .padding(.horizontal, 18)
    }

    /// The field's own row height: the full budget when untagged (shares the row with just the
    /// icon), or that budget minus the chip row's share when tagged (`AgentPanelMetrics.tagRowHeight`
    /// — the total across both rows is unchanged, only re-split; see `AgentPanelMetrics.height(for:...)`).
    private var fieldRowHeight: CGFloat {
        let total = AgentPanelMetrics.searchFieldHeight(forLineCount: lineCount)
        return model.taggedAgentLabel == nil ? total : total - AgentPanelMetrics.tagRowHeight
    }

    /// Shift+Return routing (`AgentPanelModel.routingState`): Jev thinking, or its pick waiting for a
    /// confirming Return. Its own row below the field (not squeezed beside it); the drafted message
    /// itself stays visible in the field above (never cleared until an actual send), which doubles
    /// as this row's "message preview".
    /// Key hints live only in the footer (`PanelFooterHints`) — this row is just the state, never
    /// the keys, so the two never say the same thing twice.
    @ViewBuilder
    private func routingRow(for state: AgentPanelModel.RoutingState) -> some View {
        switch state {
        case .loading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Asking Jev…")
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
        case .confirming(_, let label, _):
            Text("→ \(label)")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    /// While a card is open the search box types nothing: digits pick an
    /// option, other characters are dropped. Arrows, space, return and escape have
    /// their own handlers, and shortcuts (⌘,) pass through.
    private func answerCardKeyPress(_ press: KeyPress) -> KeyPress.Result {
        // ⌘C copies the agent's details. This handler only runs while the search box has the
        // keyboard, so a text field or a selection elsewhere in the card keeps its own copy.
        if model.isCardOpen, press.modifiers == .command, press.characters == "c" {
            return model.copyOpenCardIdentity() ? .handled : .ignored
        }
        guard model.isCardOpen, press.modifiers.subtracting(.shift).isEmpty else { return .ignored }
        switch press.key {
        case .upArrow, .downArrow, .leftArrow, .rightArrow, .space, .return, .escape, .tab:
            return .ignored
        default:
            if let number = Int(press.characters), (1...9).contains(number) { model.handleCardDigit(number) }
            else { model.handleCardStrayKey() }
            return .handled
        }
    }

    /// While tagged the field IS the message; naming who it goes to (mirrors FastTab's alias
    /// placeholder, "Search \(alias)…", the same idea one level up: name the destination).
    private var fieldPlaceholder: String {
        model.taggedAgentLabel.map { "Message \($0)…" } ?? "Search agents"
    }

    private var field: some View {
        TextField(fieldPlaceholder, text: $model.query, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(size: 18))
            .lineLimit(1...AgentPanelMetrics.searchFieldMaxLines)
            .focused($isFocused)
            .onKeyPress(.return, phases: .down) { press in
                // Consumed here, at .down, before the vertical-axis field's own Return handling
                // would otherwise insert a line break (it no longer reaches `.onSubmit`, so that
                // modifier is gone and every Return is decided in one place). Shift+Return over
                // free text starts Jev routing, unless a card already owns the keyboard; every
                // other Return presses the highlighted button / switches to the agent, exactly
                // as `.onSubmit` used to.
                if !model.isCardOpen, press.modifiers.contains(.shift) {
                    model.startRouting()
                } else {
                    model.activateSelected(isKeyRepeat: NSApp.currentEvent?.isARepeat ?? false)
                }
                return .handled
            }
            .onKeyPress(.upArrow) { model.moveSelectionOrAnswerHighlight(by: -1); return .handled }
            .onKeyPress(.downArrow) { model.moveSelectionOrAnswerHighlight(by: 1); return .handled }
            .onKeyPress(.leftArrow) { model.moveButtonHighlight(by: -1) ? .handled : .ignored }
            .onKeyPress(.rightArrow) { model.moveButtonHighlight(by: 1) ? .handled : .ignored }
            .onKeyPress(.tab, phases: .down) { _ in
                // While a card is open, Tab stays a no-op (`answerCardKeyPress` below already
                // ignores it there) rather than tagging a row the user can no longer see.
                guard !model.isCardOpen else { return .ignored }
                model.tagSelected()
                return .handled
            }
            .onKeyPress(keys: [.space], phases: .down) { press in
                guard press.modifiers.isEmpty else { return .ignored }
                return model.togglePeek() ? .handled : .ignored
            }
            .onKeyPress(phases: .down) { press in answerCardKeyPress(press) }
            .onExitCommand {
                if model.dismissFooterNotice() { return }   // a failure notice goes first, then esc does its usual job
                if model.backOutOfButtons() { return }
                if model.peek != nil { model.closePeek() } else { onClose() }
            }
            .simultaneousGesture(TapGesture().onEnded {
                NotificationCenter.default.post(name: Self.didReceiveClickNotification, object: nil)
            })
            .onAppear { isFocused = true }
            .onChange(of: model.focusRequest) {
                // The answer card's text view may have taken the keyboard without SwiftUI knowing,
                // so "focused" can already read true: flip it to make the field take it back.
                isFocused = false
                DispatchQueue.main.async { isFocused = true }
            }
    }
}

/// The tagged agent, inline in the search bar. Recreates FastTab's search-alias chip
/// (`SearchAliasBadge` in `CommandBarChrome.swift`) — same capsule, same accent tint, same ✕ —
/// since AgentBar and FastTab share only `CommandBarKit`, which has no such component to reuse.
private struct TagChipView: View {
    let label: String
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Untag \(label)")
            .help("Untag \(label)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.accentColor.opacity(0.18)))
        .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.32), lineWidth: 1))
        .fixedSize()
    }
}
