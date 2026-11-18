import SwiftUI

/// Focus mode's whole screen: the dim (the window's own blur sits under it, see
/// `FocusOverlayController`), and the centred card ≈90% of the screen: header (dot, agent, project,
/// time waiting, "2 of 4" dots), context on the left, the ask on the right, key hints at the bottom.
/// "Sent ✓" floats over the card after a send; "All clear" replaces it when the queue is empty.
struct FocusOverlayView: View {
    @ObservedObject var session: FocusSession
    let reduceMotion: Bool
    let onExit: () -> Void
    /// Offscreen renders: skip the fade-in (`onAppear` animations never run without a window).
    var startsAppeared = false
    @Environment(\.colorScheme) private var colorScheme
    @State private var appeared = false
    @State private var bumpOffset: CGFloat = 0
    /// +1 moving forward, -1 back: which edge the next card slides in from.
    @State private var direction = 1
    @State private var shownID: String?
    /// The header dot that just joined the queue: pulses once.
    @State private var pulsingDot: Int?

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black
                    .opacity(colorScheme == .dark ? FocusPalette.dimOpacityDark : FocusPalette.dimOpacityLight)
                    .ignoresSafeArea()
                    .onTapGesture {}   // swallow clicks on the dim; Esc exits
                card
                    .frame(width: geometry.size.width * 0.9, height: geometry.size.height * 0.9)
                    .background(RoundedRectangle(cornerRadius: 22).fill(FocusPalette.card))
                    .clipShape(RoundedRectangle(cornerRadius: 22))
                    .shadow(color: .black.opacity(0.35), radius: 40, y: 12)
                    .scaleEffect(appeared || reduceMotion ? 1 : 0.98)
                    .opacity(appeared || startsAppeared ? 1 : 0)
                    .offset(x: bumpOffset)
            }
        }
        .onAppear {
            shownID = session.queue.currentID
            withAnimation(.easeOut(duration: 0.18)) { appeared = true }
        }
        .onChange(of: session.queue.currentID) { old, new in
            let ids = session.queue.agentIDs
            direction = (old.flatMap(ids.firstIndex) ?? -1) > (new.flatMap(ids.firstIndex) ?? -1) ? -1 : 1
            withAnimation(reduceMotion ? .easeInOut(duration: 0.18) : .easeOut(duration: 0.22)) { shownID = new }
        }
        .onChange(of: session.queue.count) { old, new in
            guard new > old, !reduceMotion else { return }
            pulsingDot = new - 1
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(0.9))
                pulsingDot = nil
            }
        }
        .onChange(of: session.bumps) { _, _ in
            guard !reduceMotion else { return }
            withAnimation(.easeOut(duration: 0.08)) { bumpOffset = 8 }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.4).delay(0.08)) { bumpOffset = 0 }
        }
    }

    @ViewBuilder
    private var card: some View {
        if session.phase == .allClear {
            allClear.transition(.opacity)
        } else if let agent = session.currentAgent {
            VStack(spacing: 0) {
                header(agent)
                Divider().overlay(FocusPalette.line)
                ZStack {
                    content(agent)
                        .id(agent.id)
                        .transition(slide)
                }
                .clipped()
                Divider().overlay(FocusPalette.line)
                hints
            }
            .overlay { if session.phase == .sent { sentBadge } }
            .overlay(alignment: .top) { toast }
            .overlay(alignment: .bottom) { failureStrip }
        } else {
            Color.clear
        }
    }

    private var slide: AnyTransition {
        if reduceMotion { return .opacity }
        return .asymmetric(
            insertion: .move(edge: direction > 0 ? .trailing : .leading).combined(with: .opacity),
            removal: .move(edge: direction > 0 ? .leading : .trailing).combined(with: .opacity)
        )
    }

    private func header(_ agent: AgentSnapshot) -> some View {
        HStack(spacing: 14) {
            Circle()
                .fill(agent.blockedOnYou != nil ? FocusPalette.accent : Color.orange)
                .frame(width: 12, height: 12)
            Text(agent.label)
                .font(.avenir(size: 24, weight: .semibold))
                .foregroundStyle(FocusPalette.ink)
                .lineLimit(1)
            Text(subtitle(agent))
                .font(.avenir(size: 17))
                .foregroundStyle(FocusPalette.mute)
                .lineLimit(1)
            Spacer(minLength: 12)
            if session.queue.count > 1, let position = session.queue.position {
                HStack(spacing: 6) {
                    ForEach(0..<min(session.queue.count, 12), id: \.self) { index in
                        Circle()
                            .fill(index + 1 == position ? FocusPalette.accent : FocusPalette.line)
                            .frame(width: 8, height: 8)
                            .background {
                                Circle()
                                    .stroke(FocusPalette.accent, lineWidth: 2)
                                    .scaleEffect(pulsingDot == index ? 2.4 : 1)
                                    .opacity(pulsingDot == index ? 0 : (pulsingDot == nil ? 0 : 0.9))
                                    .animation(.easeOut(duration: 0.8), value: pulsingDot)
                            }
                            .scaleEffect(pulsingDot == index ? 1.35 : 1)
                            .animation(.spring(response: 0.3, dampingFraction: 0.5), value: pulsingDot)
                    }
                }
                Text("\(position) of \(session.queue.count)")
                    .font(.avenir(size: 16, weight: .medium))
                    .foregroundStyle(FocusPalette.mute)
                    .monospacedDigit()
            }
            FocusGoToButton(session: session)
                .controlSize(.large)
                .padding(.leading, 8)
        }
        .padding(.horizontal, 32)
        .frame(height: 72)
    }

    private func subtitle(_ agent: AgentSnapshot) -> String {
        var parts: [String] = []
        if let project = agent.projectName, !project.isEmpty { parts.append(project) }
        if let fetchedAt = session.model.snapshot?.fetchedAt,
           let seconds = AgentAge.seconds(for: agent, fetchedAt: fetchedAt, now: Date()) {
            parts.append("waiting \(AgentAge.shortText(seconds))")
        }
        return parts.joined(separator: " · ")
    }

    private func content(_ agent: AgentSnapshot) -> some View {
        HStack(spacing: 0) {
            FocusContextView(agent: agent, context: session.contexts[agent.id])
                .padding(32)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(FocusPalette.panel)
            Divider().overlay(FocusPalette.line)
            VStack(spacing: 0) {
                FocusAskView(session: session)
                    .padding(32)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider().overlay(FocusPalette.line)
                AgentActionRow(
                    items: actionItems(agent),
                    actionState: session.model.rowActionStates[agent.id],
                    fontSize: 15, spacing: 8,
                    onAction: { perform($0, on: agent) }
                )
                .padding(.horizontal, 32)
                .frame(height: 56)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// The shared action row's items here: Peek and Message are left out (the overlay has no peek
    /// surface, and the ask column already is the Message box for a waiting agent).
    private func actionItems(_ agent: AgentSnapshot) -> [AgentActionItem] {
        AgentActionList.items(
            for: agent, tree: session.model.treeModel.tree,
            goToDisabledReason: session.destination.flatMap { $0.isEnabled ? nil : ($0.reason ?? FocusDestination.noHomeReason) },
            hiding: Self.hiddenActions
        )
    }

    static let hiddenActions: Set<RowButton> = [.peek, .message]

    private func perform(_ action: AgentAction, on agent: AgentSnapshot) {
        switch action {
        case .close: onExit()
        case .goToAgent: session.goToAgent()
        case .row(let button): session.model.press(button, on: agent.id)
        }
    }

    private var hints: some View {
        FocusHintsBar(goToLabel: goToHint, hotkey: FocusHotkey.configured().displayName)
    }

    private var goToHint: String {
        guard let destination = session.destination else { return "go to agent" }
        return destination.isEnabled ? "go to agent (pauses Focus)" : destination.reason ?? FocusDestination.noHomeReason
    }

    @ViewBuilder
    private var toast: some View {
        if let text = session.toast {
            Text(text)
                .font(.avenir(size: 16, weight: .medium))
                .foregroundStyle(FocusPalette.ink)
                .padding(.horizontal, 18).padding(.vertical, 9)
                .background(Capsule().fill(FocusPalette.panel))
                .overlay(Capsule().strokeBorder(FocusPalette.line))
                .padding(.top, 84)
                .transition(.opacity)
                .animation(.easeOut(duration: 0.2), value: session.toast)
        }
    }

    private var sentBadge: some View {
        Label("Sent", systemImage: "checkmark")
            .font(.avenir(size: 22, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 26).padding(.vertical, 14)
            .background(Capsule().fill(FocusPalette.ok))
            .transition(.opacity)
    }

    @ViewBuilder
    private var failureStrip: some View {
        if let notice = session.model.footerNotice, notice.isDismissible {
            FooterNoticeView(notice: notice) { session.model.dismissFooterNotice() }
                .padding(.bottom, 48)
        }
    }

    private var allClear: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 72, weight: .light))
                .foregroundStyle(FocusPalette.ok)
            Text("All clear")
                .font(.avenir(size: 34, weight: .semibold))
                .foregroundStyle(FocusPalette.ink)
            Text("Nothing needs you")
                .font(.avenir(size: 20))
                .foregroundStyle(FocusPalette.mute)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture(perform: onExit)
    }
}

/// Focus mode's footer hints (pure, 2026-11-15): every key `FocusKey` handles, in display order,
/// each with a priority for `KeyHintFit` (a narrow screen drops the lowest first, never wraps).
enum FocusHints {
    struct Item: Equatable {
        let key: String
        let label: String
        let priority: Int
    }

    /// `hotkey`: the system-wide Focus shortcut's name (Settings › Shortcuts, default ⌥⇧F), which also exits.
    static func items(goToLabel: String, hotkey: String) -> [Item] {
        [
            Item(key: "↑ ↓", label: "choose", priority: 70),
            Item(key: "1–9", label: "pick", priority: 60),
            Item(key: "space", label: "tick", priority: 30),
            Item(key: "↩", label: "answer", priority: 90),
            Item(key: "⌘← ⌘→", label: "agents", priority: 80),
            Item(key: "⌘↩", label: goToLabel, priority: 50),
            Item(key: "esc / \(hotkey)", label: "exit", priority: 100),
        ]
    }
}

/// Focus mode's footer: `FocusHints` on one line, low-priority hints dropped when narrow.
struct FocusHintsBar: View {
    let goToLabel: String
    let hotkey: String

    var body: some View {
        HStack(spacing: 0) {
            FittingKeyHints(items: FocusHints.items(goToLabel: goToLabel, hotkey: hotkey), priority: \.priority, spacing: 22) { item in
                HStack(spacing: 6) {
                    Text(item.key).font(.avenirMono(size: 13, weight: .semibold))
                    Text(item.label).font(.avenir(size: 13))
                }
                .foregroundStyle(FocusPalette.mute)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 32)
        .frame(height: 48)
    }
}
