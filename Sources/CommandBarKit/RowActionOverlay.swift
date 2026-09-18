import SwiftUI
import AppKit

/// Reusable overlay for trailing action clusters on command bar rows.
///
/// Ensures row titles take the full width of the row without being squeezed or
/// truncated by static action cluster sizing. When hovering or selected, this
/// overlay smoothly fades in with a solid background that cleanly masks any
/// title text running underneath.
public struct RowActionOverlay<Content: View>: View {
    let isSelected: Bool
    let isHovering: Bool
    var isVisible: Bool = true
    var accentTint: Color? = nil
    var leadingFadeWidth: CGFloat = 18
    var trailingPadding: CGFloat = 10
    @ViewBuilder var content: Content

    public init(
        isSelected: Bool,
        isHovering: Bool,
        isVisible: Bool = true,
        accentTint: Color? = nil,
        leadingFadeWidth: CGFloat = 18,
        trailingPadding: CGFloat = 10,
        @ViewBuilder content: () -> Content
    ) {
        self.isSelected = isSelected
        self.isHovering = isHovering
        self.isVisible = isVisible
        self.accentTint = accentTint
        self.leadingFadeWidth = leadingFadeWidth
        self.trailingPadding = trailingPadding
        self.content = content()
    }

    public var body: some View {
        HStack(spacing: 0) {
            Color.clear
                .frame(width: leadingFadeWidth)

            HStack(spacing: 4) {
                content
            }
            .padding(.trailing, trailingPadding)
        }
        .frame(maxHeight: .infinity)
        .background {
            solidBackgroundView
                .mask {
                    HStack(spacing: 0) {
                        LinearGradient(
                            colors: [.clear, .black],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: leadingFadeWidth)

                        Color.black
                    }
                }
        }
        .opacity(isVisible ? 1.0 : 0.0)
        .allowsHitTesting(isVisible)
        .animation(.spring(response: 0.22, dampingFraction: 0.88), value: isVisible)
    }

    /// Fully opaque background layered to match the surface and row appearance.
    private var solidBackgroundView: some View {
        Self.solidBackground(isSelected: isSelected, isHovering: isHovering, accentTint: accentTint)
    }

    /// Opaque base layered to match the command bar surface and row states.
    @ViewBuilder
    public static func solidBackground(isSelected: Bool, isHovering: Bool, accentTint: Color? = nil) -> some View {
        ZStack {
            Color.black
            Color.primary.opacity(0.05)
            if isSelected {
                Color.accentColor.opacity(0.18)
            } else if isHovering {
                accentTint ?? Color.primary.opacity(0.04)
            }
        }
    }
}
