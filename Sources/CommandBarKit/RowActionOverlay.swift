import SwiftUI
import AppKit

/// Reusable overlay for trailing action clusters on command bar rows.
///
/// Row content reserves `reservedWidth` trailing clearance while the overlay is
/// visible (see call sites), so titles truncate before the buttons instead of
/// running underneath them. The overlay's leading fade gradient then softens
/// the handoff between the truncated text and the buttons.
public struct RowActionOverlay<Content: View>: View {
    let isSelected: Bool
    let isHovering: Bool
    var isVisible: Bool = true
    var accentTint: Color? = nil
    var base: Color = .black
    var leadingFadeWidth: CGFloat = 18
    var trailingPadding: CGFloat = 10
    @ViewBuilder var content: Content

    public init(
        isSelected: Bool,
        isHovering: Bool,
        isVisible: Bool = true,
        accentTint: Color? = nil,
        base: Color = .black,
        leadingFadeWidth: CGFloat = 18,
        trailingPadding: CGFloat = 10,
        @ViewBuilder content: () -> Content
    ) {
        self.isSelected = isSelected
        self.isHovering = isHovering
        self.isVisible = isVisible
        self.accentTint = accentTint
        self.base = base
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

    /// Horizontal space the overlay covers when visible: the buttons themselves
    /// plus their spacing, trailing padding, and the leading fade gradient.
    /// Row content must reserve this much trailing padding while the overlay
    /// is visible — otherwise `ViewThatFits` measures the full row width,
    /// picks a variant that only fits without the overlay, and the title runs
    /// underneath the buttons.
    public static func reservedWidth(
        buttonCount: Int,
        buttonDiameter: CGFloat = 22,
        buttonSpacing: CGFloat = 4,
        leadingFadeWidth: CGFloat = 18,
        trailingPadding: CGFloat = 10
    ) -> CGFloat {
        guard buttonCount > 0 else { return 0 }
        return CGFloat(buttonCount) * buttonDiameter
            + CGFloat(buttonCount - 1) * buttonSpacing
            + leadingFadeWidth
            + trailingPadding
    }

    /// Fully opaque background layered to match the surface and row appearance.
    private var solidBackgroundView: some View {
        Self.solidBackground(isSelected: isSelected, isHovering: isHovering, accentTint: accentTint, base: base)
    }

    /// Opaque base layered to match the command bar surface and row states.
    /// `base` is the surface behind the row: `.black` for the command bar's
    /// dark panel (default), or e.g. `Color(nsColor: .windowBackgroundColor)`
    /// for rows hosted in a regular Settings window.
    @ViewBuilder
    public static func solidBackground(isSelected: Bool, isHovering: Bool, accentTint: Color? = nil, base: Color = .black) -> some View {
        ZStack {
            base
            Color.primary.opacity(0.05)
            if isSelected {
                Color.accentColor.opacity(0.18)
            } else if isHovering {
                accentTint ?? Color.primary.opacity(0.04)
            }
        }
    }
}
