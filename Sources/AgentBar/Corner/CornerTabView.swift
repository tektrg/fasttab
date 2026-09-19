import SwiftUI

/// What the corner tab currently shows and whether it has slid in.
@MainActor
final class CornerTabViewState: ObservableObject {
    @Published var content = CornerTabContent(count: 0, newestName: "")
    @Published var isSlidIn = false
}

/// The pill: an orange dot, "3 need you", and the newest arrival's name.
/// Same material and outline as the panel. Slides in from the display's right
/// edge; the window clips it.
struct CornerTabView: View {
    @ObservedObject var state: CornerTabViewState
    let onClick: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            tab
                .offset(x: state.isSlidIn ? 0 : CornerTabPlacement.tabWidth + AgentPanelPlacement.edgeMargin)
            Spacer(minLength: 0)
        }
        .frame(width: CornerTabPlacement.tabWidth + AgentPanelPlacement.edgeMargin, height: CornerTabPlacement.tabHeight)
    }

    private var tab: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(AgentSection.needsYou.dotColor)
                .frame(width: 9, height: 9)
            Text(state.content.headline)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .fixedSize()
            Text("· \(state.content.newestName)")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(width: CornerTabPlacement.tabWidth, height: CornerTabPlacement.tabHeight)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.12)))
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .onTapGesture(perform: onClick)
    }
}
