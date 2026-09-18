import SwiftUI

/// Floating swatch bar that slides up from the bottom when the user selects text
/// in the reader WebView. Posts the chosen colour back via `onSelectColor`.
public struct ReaderHighlightBar: View {
    public let selectedText: String
    public let onSelectColor: (HighlightColor) -> Void
    public let onDismiss: () -> Void

    @State private var appeared = false

    public init(
        selectedText: String,
        onSelectColor: @escaping (HighlightColor) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.selectedText = selectedText
        self.onSelectColor = onSelectColor
        self.onDismiss = onDismiss
    }

    public var body: some View {
        VStack(spacing: 12) {
            // Preview of selected text
            if !selectedText.isEmpty {
                Text("\"\(selectedText.prefix(80))\(selectedText.count > 80 ? "…" : "")\"")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .padding(.horizontal, 20)
            }

            HStack(spacing: 20) {
                ForEach(HighlightColor.allCases, id: \.rawValue) { color in
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        onSelectColor(color)
                    } label: {
                        Circle()
                            .fill(color.swiftUIColor.opacity(0.85))
                            .overlay(Circle().stroke(Color.primary.opacity(0.15), lineWidth: 1))
                            .frame(width: 36, height: 36)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Highlight \(color.label)")
                }

                Divider()
                    .frame(height: 28)

                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.15), radius: 16, y: -4)
        )
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        .offset(y: appeared ? 0 : 120)
        .opacity(appeared ? 1 : 0)
        .onAppear {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                appeared = true
            }
        }
    }
}
