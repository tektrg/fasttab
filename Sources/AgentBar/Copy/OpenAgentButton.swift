import SwiftUI

/// A small "bring this agent to front" button, shown next to `CopyIdentityButton` on a card header.
struct OpenAgentButton: View {
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            Image(systemName: "arrow.up.forward.app")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open agent")
        .accessibilityLabel("Open agent")
    }
}
