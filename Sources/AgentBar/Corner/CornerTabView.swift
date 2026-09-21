import SwiftUI

/// What the corner window currently shows: the summary pill, or the sole blocked agent's live
/// card (`CornerTabController`/`CornerTabMachine` decide which; this view only draws it).
enum CornerTabDisplayMode: Equatable {
    case pill
    case card
}

/// What the corner tab currently shows and whether it has slid in.
@MainActor
final class CornerTabViewState: ObservableObject {
    @Published var content = CornerTabContent(count: 0, newestName: "")
    @Published var isSlidIn = false
    @Published var mode: CornerTabDisplayMode = .pill
}

/// The corner window's content: either the pill (an orange dot, "3 need you", and the newest
/// arrival's name; a grey dot and "Nothing needs you · AgentBar" when nobody needs the user; a red
/// dot and "waiting for your answer" while someone is blocked, and then the tab stays), or, once
/// exactly one agent is blocked with something answerable, that agent's live card (`CornerCardView`)
/// in its place. Same material and outline as the panel. Slides in from the display's right edge;
/// the window clips it.
struct CornerTabView: View {
    @ObservedObject var state: CornerTabViewState
    @ObservedObject var model: AgentPanelModel
    /// The pill tap, and the card's own expand affordance: both open the full panel.
    let onOpenPanel: () -> Void
    /// The ✕ on the pill and on the card: hide the corner without answering.
    let onDismiss: () -> Void
    let onOpenSettings: () -> Void

    private var contentWidth: CGFloat {
        state.mode == .card ? AgentPanelMetrics.width : CornerTabPlacement.tabWidth
    }
    private var contentHeight: CGFloat {
        state.mode == .card ? CornerTabPlacement.cardHeight : CornerTabPlacement.tabHeight
    }

    var body: some View {
        HStack(spacing: 0) {
            content
                .offset(x: state.isSlidIn ? 0 : contentWidth + AgentPanelPlacement.edgeMargin)
            Spacer(minLength: 0)
        }
        .frame(width: contentWidth + AgentPanelPlacement.edgeMargin, height: contentHeight)
    }

    @ViewBuilder
    private var content: some View {
        switch state.mode {
        case .pill: pill
        case .card: CornerCardView(model: model, onExpand: onOpenPanel, onDismiss: onDismiss, onOpenSettings: onOpenSettings)
        }
    }

    /// Red once someone must answer or approve (like the red Answer / Review button), else orange; grey when idle.
    private var dotColor: Color {
        if state.content.blockedCount > 0 { return .red }
        return state.content.count == 0 ? .secondary : AgentSection.needsYou.dotColor
    }

    private var pill: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(dotColor)
                .frame(width: 9, height: 9)
            Text(state.content.headline)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .fixedSize()
            Text("· \(state.content.detail)")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            CornerDismissButton(action: onDismiss)
        }
        .padding(.horizontal, 14)
        .frame(width: CornerTabPlacement.tabWidth, height: CornerTabPlacement.tabHeight)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.12)))
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .onTapGesture(perform: onOpenPanel)
    }
}
