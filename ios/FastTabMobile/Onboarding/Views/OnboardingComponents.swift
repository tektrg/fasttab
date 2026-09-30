import SwiftUI

/// Every guide screen has the same shape: animated hero, headline, one-line
/// explanation, the screen's own content, then its buttons pinned at the bottom.
struct OnboardingStepLayout<Hero: View, Content: View, Actions: View>: View {
    let title: String
    let message: String?
    let hero: Hero
    let content: Content
    let actions: Actions
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// The scroll area's size and the height of everything under the hero: the hero
    /// takes whatever room is left, so the animation fills the screen.
    @State private var scrollAreaSize = CGSize.zero
    @State private var belowHeroHeight: CGFloat = 0

    init(
        title: String,
        message: String? = nil,
        @ViewBuilder hero: () -> Hero,
        @ViewBuilder content: () -> Content,
        @ViewBuilder actions: () -> Actions
    ) {
        self.title = title
        self.message = message
        self.hero = hero()
        self.content = content()
        self.actions = actions()
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: DS.Space.lg) {
                    // Decorative; at accessibility text sizes the pinned buttons
                    // already take much of the screen, so the words get its room.
                    // (Heroes hide themselves from VoiceOver: `OnboardingHeroStage`.)
                    if !dynamicTypeSize.isAccessibilitySize {
                        hero
                            .environment(\.onboardingHeroScale, heroScale)
                    }

                    VStack(spacing: DS.Space.lg) {
                        VStack(spacing: DS.Space.sm) {
                            Text(title)
                                .font(DS.Font.display)
                                .accessibilityAddTraits(.isHeader)
                            if let message {
                                Text(message)
                                    .font(DS.Font.body)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)

                        content
                            .padding(.top, DS.Space.sm)
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                        withoutAnimation { belowHeroHeight = height }
                    }
                }
                .padding(.top, OnboardingHeroSizing.topPadding)
                .padding(.horizontal, DS.Space.xl)
                .padding(.bottom, DS.Space.xl)
            }
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                withoutAnimation { scrollAreaSize = size }
            }
            .scrollBounceBehavior(.basedOnSize)

            VStack(spacing: DS.Space.sm) {
                actions
            }
            .padding(.horizontal, DS.Space.xl)
            .padding(.top, DS.Space.sm)
            .padding(.bottom, DS.Space.md)
        }
    }

    private var heroScale: Double {
        OnboardingHeroSizing.scale(
            scrollAreaSize: scrollAreaSize,
            belowHeroHeight: belowHeroHeight,
            heroGap: DS.Space.lg,
            horizontalPadding: DS.Space.xl,
            verticalPadding: OnboardingHeroSizing.topPadding + DS.Space.xl
        )
    }

    /// Size changes come from measuring, so never animate the hero growing mid-slide.
    private func withoutAnimation(_ change: () -> Void) {
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant, change)
    }
}

/// The hero is the screen's key element: it grows to fill the height the words
/// and buttons leave, up to the full content width, and never below `minimumScale`
/// (then the page scrolls).
enum OnboardingHeroSizing {
    static let minimumScale = 5.0 / 6.0
    static let topPadding = DS.Space.lg

    static func scale(
        scrollAreaSize: CGSize,
        belowHeroHeight: CGFloat,
        heroGap: CGFloat,
        horizontalPadding: CGFloat,
        verticalPadding: CGFloat
    ) -> Double {
        let canvas = OnboardingHeroStage<EmptyView>.canvasSize
        guard scrollAreaSize.height > 0, scrollAreaSize.width > 0 else { return 1 }
        let widthLimit = (scrollAreaSize.width - 2 * horizontalPadding) / canvas.width
        // 1 pt spare so rounding never makes the page scroll by a hair.
        let freeHeight = scrollAreaSize.height - verticalPadding - heroGap - belowHeroHeight - 1
        let heightLimit = freeHeight / canvas.height
        return max(minimumScale, min(widthLimit, heightLimit))
    }
}

/// Full-width primary button used for each screen's main action.
struct OnboardingPrimaryButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).frame(maxWidth: .infinity)
        }
        .buttonStyle(.dsPrimary)
    }
}

/// Quiet text button under the primary one ("Continue without a Mac").
struct OnboardingSecondaryButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(title, action: action)
            .font(DS.Font.control)
            .foregroundStyle(.secondary)
            .padding(.vertical, DS.Space.xs)
    }
}

/// Tinted icon + title + detail. Welcome benefits and the closing tab tour.
struct OnboardingFeatureRow: View {
    let systemImage: String
    let tint: Color
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.md) {
            Image(systemName: systemImage)
                .font(.system(size: DS.IconSize.row + 4))
                .foregroundStyle(tint)
                .frame(width: 36, height: 36)
                .background(tint.opacity(DS.tintFillOpacity), in: RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text(title)
                    .font(DS.Font.cardTitle)
                Text(detail)
                    .font(DS.Font.meta)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

/// "1 · Tap Share" style instruction line with a symbol showing what to look for.
struct OnboardingNumberedInstruction: View {
    let number: Int
    let text: String
    let systemImage: String
    /// Grows the number badge with Dynamic Type so the digit never clips.
    @ScaledMetric(relativeTo: .body) private var badgeSize: CGFloat = 24
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        // At accessibility sizes the text needs the whole row: the badge sits on
        // its first line and the decorative symbol goes.
        HStack(alignment: dynamicTypeSize.isAccessibilitySize ? .firstTextBaseline : .center, spacing: DS.Space.md) {
            Text("\(number)")
                .font(DS.Font.control.monospacedDigit())
                .foregroundStyle(.white)
                .frame(width: badgeSize, height: badgeSize)
                .background(DS.Tint.action, in: Circle())
            Text(text)
                .font(DS.Font.body)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: DS.Space.sm)
            if !dynamicTypeSize.isAccessibilitySize {
                Image(systemName: systemImage)
                    .font(.system(size: DS.IconSize.row + 2))
                    .foregroundStyle(DS.Tint.action)
                    .frame(width: 32, height: 32)
                    .background(DS.Palette.surfaceMuted, in: RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous))
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Page dots for the full guide.
struct OnboardingPageDots: View {
    let count: Int
    let currentIndex: Int

    var body: some View {
        HStack(spacing: DS.Space.sm) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(index == currentIndex ? DS.Tint.action : DS.Palette.surfaceMuted)
                    .frame(width: index == currentIndex ? 18 : 7, height: 7)
            }
        }
        .animation(DS.Motion.quick, value: currentIndex)
        .accessibilityElement()
        .accessibilityLabel("Step \(currentIndex + 1) of \(count)")
    }
}
