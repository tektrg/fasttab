import SwiftUI

/// Search box at the top of the panel; grabs keyboard focus on every show.
/// ←/→ walk the selected row's buttons, but only while the box is empty (with
/// text in it they move the caret); Enter presses the highlighted button, else
/// switches to the agent.
struct SearchFieldView: View {
    @ObservedObject var model: AgentPanelModel
    let onClose: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            field
        }
        .padding(.horizontal, 18)
        .frame(height: AgentPanelMetrics.searchFieldHeight)
    }

    private var field: some View {
        TextField("Search agents", text: $model.query)
            .textFieldStyle(.plain)
            .font(.system(size: 18))
            .focused($isFocused)
            .onSubmit { model.activateSelected() }
            .onKeyPress(.upArrow) { model.moveSelection(by: -1); return .handled }
            .onKeyPress(.downArrow) { model.moveSelection(by: 1); return .handled }
            .onKeyPress(.leftArrow) { model.moveButtonHighlight(by: -1) ? .handled : .ignored }
            .onKeyPress(.rightArrow) { model.moveButtonHighlight(by: 1) ? .handled : .ignored }
            .onKeyPress(keys: [.space], phases: .down) { press in
                guard press.modifiers.isEmpty else { return .ignored }
                return model.togglePeek() ? .handled : .ignored
            }
            .onExitCommand {
                if model.backOutOfButtons() { return }
                if model.peek != nil { model.closePeek() } else { onClose() }
            }
            .onAppear { isFocused = true }
            .onChange(of: model.focusRequest) { isFocused = true }
    }
}
