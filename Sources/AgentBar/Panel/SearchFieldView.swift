import SwiftUI

/// Search box at the top of the panel; grabs keyboard focus on every show.
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
            .onExitCommand(perform: onClose)
            .onAppear { isFocused = true }
            .onChange(of: model.focusRequest) { isFocused = true }
    }
}
