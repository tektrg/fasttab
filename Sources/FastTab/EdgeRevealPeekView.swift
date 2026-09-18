import SwiftUI
import CommandBarKit

/// Illustrates the notch/edge trigger during onboarding — shaped like a
/// half-capsule flush against the screen edge it hugs (modeled on the
/// reference notch-companion app this feature is patterned on), so the
/// picture matches what actually sits at that edge once hovering is live.
/// Not used at runtime: the live trigger opens the command bar directly
/// (see `EdgeRevealService`) rather than showing an intermediate pill.
struct EdgeRevealPeekView: View {
    let style: EdgeRevealStyle

    private var size: CGSize { EdgeRevealGeometry.pillSize(for: style) }
    private var cornerRadius: CGFloat { min(size.width, size.height) / 2 }

    private var corners: (topLeading: CGFloat, bottomLeading: CGFloat, bottomTrailing: CGFloat, topTrailing: CGFloat) {
        switch style {
        case .off:
            return (cornerRadius, cornerRadius, cornerRadius, cornerRadius)
        case .notch:
            // Flush to the top of the screen — square top, rounded bottom.
            return (0, cornerRadius, cornerRadius, 0)
        case .leftEdge:
            // Flush to the left edge — square left side, rounded right.
            return (0, 0, cornerRadius, cornerRadius)
        case .rightEdge:
            // Flush to the right edge — square right side, rounded left.
            return (cornerRadius, cornerRadius, 0, 0)
        }
    }

    var body: some View {
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: corners.topLeading,
            bottomLeadingRadius: corners.bottomLeading,
            bottomTrailingRadius: corners.bottomTrailing,
            topTrailingRadius: corners.topTrailing,
            style: .continuous
        )

        Image(systemName: "command")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: size.width, height: size.height)
            .background(shape.fill(.regularMaterial))
            .overlay(shape.strokeBorder(Color.primary.opacity(0.1), lineWidth: 1))
    }
}
