import SwiftUI

/// Reusable floating pill-bar sub-navigation component with smooth spring animations,
/// haptic feedback, and glassmorphic material styling.
public struct FloatingSubTabBar<Tab: CaseIterable & Identifiable & Hashable & Equatable>: View {
    @Binding public var selection: Tab
    public let iconProvider: (Tab) -> String
    public let titleProvider: (Tab) -> String
    
    @Namespace private var animation

    public init(
        selection: Binding<Tab>,
        iconProvider: @escaping (Tab) -> String,
        titleProvider: @escaping (Tab) -> String
    ) {
        self._selection = selection
        self.iconProvider = iconProvider
        self.titleProvider = titleProvider
    }

    public var body: some View {
        HStack(spacing: DS.Space.xs) {
            ForEach(Array(Tab.allCases), id: \.id) { tab in
                let isSelected = selection == tab
                Button {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) {
                        selection = tab
                    }
                    UISelectionFeedbackGenerator().selectionChanged()
                } label: {
                    HStack(spacing: DS.Space.xs) {
                        Image(systemName: iconProvider(tab))
                            .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                        Text(titleProvider(tab))
                            .font(.subheadline.weight(isSelected ? .semibold : .medium))
                    }
                    .padding(.horizontal, DS.Space.md)
                    .padding(.vertical, DS.Space.sm)
                    .foregroundColor(isSelected ? .primary : .secondary)
                    .background {
                        if isSelected {
                            Capsule()
                                .fill(DS.Palette.surface)
                                .shadow(color: .black.opacity(0.12), radius: 4, y: 1.5)
                                .matchedGeometryEffect(id: "ActiveSubTabPill", in: animation)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(DS.Space.xs)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.45),
                            Color.white.opacity(0.15)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.75
                )
        )
        .dsShadow(.floating)
    }
}
