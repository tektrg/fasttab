import SwiftUI

// Reusable building blocks on top of `DSTokens`. Screens compose these instead of
// restyling the same capsule / header / empty state by hand.

// MARK: - Surfaces

public extension View {
    /// The warm page background, edge to edge. Custom (non-List) screens.
    func dsCanvas() -> some View {
        background(DS.Palette.canvas.ignoresSafeArea())
    }

    /// Native List on the warm canvas. Rows keep the List's own background unless the
    /// screen also applies `.dsListRow()`.
    func dsListStyle() -> some View {
        scrollContentBackground(.hidden)
            .dsCanvas()
    }

    /// Row background for a List styled with `.dsListStyle()`. Apply on a Section or ForEach.
    func dsListRow() -> some View {
        listRowBackground(DS.Palette.surface)
    }

    /// A card resting on the canvas: surface fill, `Radius.lg`, faint shadow.
    func dsCard(padding: CGFloat? = DS.Space.lg, radius: CGFloat = DS.Radius.lg) -> some View {
        self
            .padding(padding ?? 0)
            .background(DS.Palette.surface, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .dsShadow(.card)
    }
}

// MARK: - Section header

/// Title (+ optional muted context) on the left, optional trailing control on the right.
/// Carries the page gutter itself.
public struct DSSectionHeader<Trailing: View>: View {
    let title: String
    let context: String?
    let trailing: Trailing

    public init(_ title: String, context: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.context = context
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.sm) {
            Text(title)
                .font(DS.Font.sectionTitle)
                .foregroundStyle(.primary)
                .accessibilityAddTraits(.isHeader)
            if let context {
                Text(context)
                    .font(DS.Font.meta.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: DS.Space.sm)
            trailing
        }
        .padding(.horizontal, DS.Space.gutter)
    }
}

public extension DSSectionHeader where Trailing == EmptyView {
    init(_ title: String, context: String? = nil) {
        self.init(title, context: context) { EmptyView() }
    }
}

// MARK: - Pills, tags, chips

/// Neutral capsule with a number: "12".
public struct DSCountPill: View {
    let count: Int
    public init(_ count: Int) { self.count = count }

    public var body: some View {
        Text("\(count)")
            .font(DS.Font.tag.monospacedDigit())
            .foregroundStyle(.secondary)
            .padding(.horizontal, DS.Space.sm)
            .padding(.vertical, 3)
            .background(DS.Palette.surfaceMuted, in: Capsule())
    }
}

/// Small tinted label: source / folder / status of an item. Not tappable.
public struct DSTag: View {
    let text: String
    let tint: Color
    let systemImage: String?

    public init(_ text: String, tint: Color, systemImage: String? = nil) {
        self.text = text
        self.tint = tint
        self.systemImage = systemImage
    }

    public var body: some View {
        HStack(spacing: 3) {
            if let systemImage {
                Image(systemName: systemImage).imageScale(.small)
            }
            Text(text)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .font(DS.Font.tag)
        .foregroundStyle(tint)
        .padding(.horizontal, 6)
        .padding(.vertical, DS.Space.xxs)
        .background(tint.opacity(DS.tintFillOpacity), in: Capsule())
    }
}

/// Filter chip: filled `primary` when selected, muted when not.
public struct DSChip: View {
    let title: String
    let systemImage: String?
    let isSelected: Bool
    let action: () -> Void

    public init(_ title: String, systemImage: String? = nil, isSelected: Bool, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.isSelected = isSelected
        self.action = action
    }

    public var body: some View {
        Button {
            withAnimation(DS.Motion.quick) { action() }
        } label: {
            HStack(spacing: 5) {
                if let systemImage {
                    Image(systemName: systemImage).imageScale(.small)
                }
                Text(title).lineLimit(1)
            }
            .font(DS.Font.control)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .foregroundStyle(isSelected ? Color(uiColor: .systemBackground) : Color.primary)
            .background(isSelected ? Color.primary : DS.Palette.surfaceMuted, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Buttons

/// Soft tinted capsule: secondary actions in headers and cards ("Shuffle", "Save All").
public struct DSTintedButtonStyle: ButtonStyle {
    let tint: Color
    public init(tint: Color) { self.tint = tint }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DS.Font.control)
            .foregroundStyle(tint)
            .padding(.horizontal, DS.Space.md)
            .padding(.vertical, 6)
            .background(tint.opacity(DS.tintFillOpacity), in: Capsule())
            .opacity(configuration.isPressed ? 0.6 : 1)
            .contentShape(Capsule())
    }
}

/// Solid capsule: the one main action of a screen or empty state.
public struct DSPrimaryButtonStyle: ButtonStyle {
    let tint: Color
    public init(tint: Color = DS.Tint.action) { self.tint = tint }

    public func makeBody(configuration: Configuration) -> some View {
        PrimaryLabel(configuration: configuration, tint: tint)
    }

    /// Separate view so it can read `isEnabled`: disabled turns the capsule grey.
    private struct PrimaryLabel: View {
        let configuration: Configuration
        let tint: Color
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(DS.Font.cardTitle)
                .foregroundStyle(isEnabled ? Color.white : Color.secondary)
                .padding(.horizontal, DS.Space.xl)
                .padding(.vertical, DS.Space.md)
                .background(isEnabled ? tint : DS.Palette.surfaceMuted, in: Capsule())
                .opacity(configuration.isPressed ? 0.75 : 1)
                .contentShape(Capsule())
        }
    }
}

public extension ButtonStyle where Self == DSTintedButtonStyle {
    static func dsTinted(_ tint: Color) -> DSTintedButtonStyle { DSTintedButtonStyle(tint: tint) }
}

public extension ButtonStyle where Self == DSPrimaryButtonStyle {
    static var dsPrimary: DSPrimaryButtonStyle { DSPrimaryButtonStyle() }
    static func dsPrimary(_ tint: Color) -> DSPrimaryButtonStyle { DSPrimaryButtonStyle(tint: tint) }
}

// MARK: - Empty states

/// "Nothing here yet". `.inline` sits inside a feed section as a card; `.fullScreen`
/// centers in an empty screen or list.
public struct DSEmptyState<Actions: View>: View {
    public enum Style { case inline, fullScreen }

    let systemImage: String
    let title: String
    let message: String?
    let tint: Color
    let style: Style
    let actions: Actions

    public init(
        _ title: String,
        systemImage: String,
        message: String? = nil,
        tint: Color = .secondary,
        style: Style = .fullScreen,
        @ViewBuilder actions: () -> Actions
    ) {
        self.title = title
        self.systemImage = systemImage
        self.message = message
        self.tint = tint
        self.style = style
        self.actions = actions()
    }

    public var body: some View {
        switch style {
        case .inline:
            HStack(alignment: .top, spacing: DS.Space.md) {
                Image(systemName: systemImage)
                    .font(.system(size: DS.IconSize.inline))
                    .foregroundStyle(tint)
                    .frame(width: DS.IconSize.inline + 4)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(DS.Font.cardTitle)
                        .foregroundStyle(.primary)
                    if let message {
                        Text(message)
                            .font(DS.Font.meta)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    actions
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .dsCard()
        case .fullScreen:
            VStack(spacing: DS.Space.md) {
                Image(systemName: systemImage)
                    .font(.system(size: DS.IconSize.hero))
                    .foregroundStyle(tint)
                    .padding(.bottom, DS.Space.xs)
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                if let message {
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                actions
                    .padding(.top, DS.Space.sm)
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, DS.Space.xxl)
            .frame(maxWidth: .infinity)
        }
    }
}

public extension DSEmptyState where Actions == EmptyView {
    init(_ title: String, systemImage: String, message: String? = nil, tint: Color = .secondary, style: Style = .fullScreen) {
        self.init(title, systemImage: systemImage, message: message, tint: tint, style: style) { EmptyView() }
    }
}
