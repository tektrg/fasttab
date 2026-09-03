import SwiftUI
import AppKit

enum ResultSwipeAction: Equatable {
    case delete
    case copy

    var iconName: String {
        switch self {
        case .delete: return "checkmark"
        case .copy: return "link"
        }
    }

    var tint: Color {
        switch self {
        case .delete: return .green
        case .copy: return .accentColor
        }
    }

    var sign: CGFloat {
        switch self {
        case .delete: return -1
        case .copy: return 1
        }
    }
}

enum ResultSwipeMetrics {
    static let revealDistance: CGFloat = 74
    static let confirmDistance: CGFloat = 138
    static let maximumOffset: CGFloat = 158
    static let actionIconInset: CGFloat = 8

    /// How far the row's content keeps sliding once removal is confirmed —
    /// well past `maximumOffset`, so the row visibly continues its swipe
    /// motion off to the side rather than snapping back before it collapses.
    /// Clipped by the row's own `clipShape`, so it doesn't need to match the
    /// row's actual width.
    static let removalExitDistance: CGFloat = 260

    /// Minimal rows are much shorter than Full rows — a full-size 30pt action
    /// icon would overflow the row height, so it scales down with the style.
    static func actionIconSize(for rowStyle: ResultRowStyle) -> CGFloat {
        rowStyle == .minimal ? 22 : 30
    }
}

/// Result row display density, set in Settings. Full shows every metadata cue
/// (type glyph, recency, pills, URL/path); Minimal shows only the leading
/// icon and title, for fast scanning.
enum ResultRowStyle: String, CaseIterable, Identifiable {
    case full
    case minimal

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .full: return "Full"
        case .minimal: return "Minimal"
        }
    }
}

struct SwipeableResultRow: View {
    let result: BrowserSearchResult
    let isSelected: Bool
    let faviconImage: NSImage?
    let showWindowName: Bool
    let showProfileName: Bool
    let pointerAction: ResultSwipeAction?
    let pointerOffset: CGFloat
    let keyboardAction: ResultSwipeAction?
    let isConfirmingRemoval: Bool
    let onHoverChange: (Bool) -> Void

    @AppStorage(CommandBarAppearance.resultRowStyleKey) private var rowStyle: ResultRowStyle = .minimal

    private var visibleAction: ResultSwipeAction? {
        pointerAction ?? keyboardAction ?? action(for: pointerOffset)
    }

    private var visibleOffset: CGFloat {
        if abs(pointerOffset) > 0 {
            return pointerOffset
        }

        if let keyboardAction {
            return keyboardAction.sign * ResultSwipeMetrics.revealDistance
        }

        return 0
    }

    private var tailIconOpacity: Double {
        guard visibleAction != nil else { return 0 }
        let visibleSpace = abs(visibleOffset)
        let minimumSpace = ResultSwipeMetrics.actionIconSize(for: rowStyle) + (ResultSwipeMetrics.actionIconInset * 2)
        guard visibleSpace >= minimumSpace else { return 0 }

        let progress = (visibleSpace - minimumSpace) / (ResultSwipeMetrics.revealDistance - minimumSpace)
        return min(1, max(0, Double(progress)))
    }

    /// Once removal is confirmed, the content keeps sliding in the same
    /// direction it was already swiping — continuing the gesture instead of
    /// snapping back to rest before the row collapses.
    private var contentOffset: CGFloat {
        isConfirmingRemoval ? -ResultSwipeMetrics.removalExitDistance : visibleOffset
    }

    var body: some View {
        ZStack {
            ResultRowView(
                result: result,
                isSelected: isSelected,
                faviconImage: faviconImage,
                showWindowName: showWindowName,
                showProfileName: showProfileName
            )
            .offset(x: contentOffset)
            .animation(.spring(response: 0.24, dampingFraction: 0.88), value: keyboardAction)
            .animation(.spring(response: 0.24, dampingFraction: 0.88), value: pointerAction)
            .animation(.easeOut(duration: 0.22), value: isConfirmingRemoval)

            if let visibleAction {
                // While confirming, the checkmark already on screen from the
                // swipe reveal takes over the flourish in place — swapping to
                // a *different* icon view here would be an invisible no-op at
                // the handoff instant (both render as the same green
                // checkmark circle), so there's no pop, just a continuation.
                Group {
                    if isConfirmingRemoval {
                        RemovalConfirmationIcon(size: ResultSwipeMetrics.actionIconSize(for: rowStyle))
                    } else {
                        TailSwipeActionIcon(action: visibleAction, size: ResultSwipeMetrics.actionIconSize(for: rowStyle))
                            .opacity(tailIconOpacity)
                            .scaleEffect(0.86 + (0.14 * CGFloat(tailIconOpacity)))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: visibleAction.tailAlignment)
                .padding(.horizontal, ResultSwipeMetrics.actionIconInset)
                .allowsHitTesting(false)
                .animation(.spring(response: 0.24, dampingFraction: 0.88), value: keyboardAction)
                .animation(.spring(response: 0.24, dampingFraction: 0.88), value: pointerAction)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onHover(perform: onHoverChange)
    }

    private func action(for offset: CGFloat) -> ResultSwipeAction? {
        if offset <= -1 { return .delete }
        if offset >= 1 { return .copy }
        return nil
    }
}

private extension ResultSwipeAction {
    var tailAlignment: Alignment {
        switch self {
        case .delete: return .trailing
        case .copy: return .leading
        }
    }
}

private struct TailSwipeActionIcon: View {
    let action: ResultSwipeAction
    let size: CGFloat

    var body: some View {
        Image(systemName: action.iconName)
            .font(.system(size: size * 0.5, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                Circle()
                    .fill(action.tint)
                    .shadow(color: action.tint.opacity(0.28), radius: 8, y: 3)
            )
    }
}

/// One-shot "removed" flourish: takes over from the resting swipe-reveal
/// checkmark (same size/color, so the handoff is invisible), briefly follows
/// the row's exit slide, then zooms in a touch and fades. Purely decorative
/// (no hit testing) — starts at the tail icon's own resting scale/opacity so
/// there's no pop at the moment it takes over.
private struct RemovalConfirmationIcon: View {
    let size: CGFloat

    @State private var scale: CGFloat = 1
    @State private var opacity: Double = 1

    var body: some View {
        Circle()
            .fill(Color.green)
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: "checkmark")
                    .font(.system(size: size * 0.5, weight: .bold))
                    .foregroundStyle(.white)
            )
            .scaleEffect(scale)
            .opacity(opacity)
            .onAppear {
                // Delayed slightly so the checkmark reads as "following" the
                // content's exit slide rather than firing the instant it's
                // confirmed.
                withAnimation(.spring(response: 0.24, dampingFraction: 0.62).delay(0.08)) {
                    scale = 1.3
                }
                withAnimation(.easeOut(duration: 0.22).delay(0.14)) {
                    opacity = 0
                }
            }
    }
}

private struct ResultRowView: View {
    let result: BrowserSearchResult
    let isSelected: Bool
    let faviconImage: NSImage?
    let showWindowName: Bool
    let showProfileName: Bool

    @Environment(\.isCompactCommandBar) private var isCompact
    @AppStorage(CommandBarAppearance.resultRowStyleKey) private var rowStyle: ResultRowStyle = .minimal

    private var secondaryMetadata: [String] {
        result.secondaryMetadata(showWindowName: showWindowName, showProfileName: showProfileName)
    }

    var body: some View {
        HStack(spacing: 10) {
            LeadingIconColumn(browserName: result.browserName, fallbackSymbol: result.type.symbolName, faviconImage: faviconImage)
                .frame(maxHeight: .infinity, alignment: .top)

            Group {
                if rowStyle == .minimal {
                    minimalContent
                } else {
                    fullContent
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
        }
        .opacity(result.type.dimmingOpacity)
        .padding(.horizontal, 10)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.17) : Color.clear)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(isSelected ? Color.accentColor.opacity(0.3) : .clear, lineWidth: 1)
                )
        )
        .scaleEffect(isSelected ? 1.01 : 1)
        .animation(.spring(response: 0.24, dampingFraction: 0.88), value: isSelected)
    }

    @ViewBuilder
    private var fullContent: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                if result.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                if result.isPinnedAudibleTab || result.hasMediaIndicator {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }

                Text(result.title)
                    .font(.system(size: 13, weight: .semibold, design: .default))
                    .foregroundStyle(result.isDiscarded ? .tertiary : .primary)
                    .lineLimit(isCompact ? 2 : 1)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Wraps at the narrow edge-anchored width, where the type
            // glyph, pills, and URL can't share a single row.
            WrappingHStack(horizontalSpacing: 5, verticalSpacing: 4) {
                Image(systemName: result.type.symbolName)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)

                if let recency = result.relativeRecencyLabel {
                    MetadataPill(title: recency)
                }

                ForEach(secondaryMetadata, id: \.self) { metadata in
                    MetadataPill(title: metadata)
                }

                Text(result.secondaryBaseText)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
    }

    /// Which browser window the tab lives in, only when that's actually
    /// informative — several windows are open for the browser (the same
    /// signal Full mode uses to decide whether to show the window pill at
    /// all) and the tab has a real window name to show. Finder windows are
    /// excluded: their "window name" is just the folder name, already
    /// implied by the result's own title/path.
    private var windowTag: String? {
        guard showWindowName,
              result.type == .tab,
              result.browserName != "Finder",
              let windowName = result.windowName,
              !windowName.isEmpty else {
            return nil
        }
        return windowName
    }

    /// Icon + title, single line. The window tag (if there are multiple
    /// windows open) and the URL/path's last segment are shown inline after
    /// the title when there's room — degrading from both, to just the
    /// window tag, to just the slug, to the title alone, whichever fits
    /// without truncating.
    @ViewBuilder
    private var minimalContent: some View {
        switch (windowTag, result.urlPathSlug) {
        case (let tag?, let slug?):
            ViewThatFits(in: .horizontal) {
                minimalLine(tag: tag, slug: slug)
                minimalLine(tag: tag)
                minimalLine(slug: slug)
                minimalTitle
            }
        case (let tag?, nil):
            ViewThatFits(in: .horizontal) {
                minimalLine(tag: tag)
                minimalTitle
            }
        case (nil, let slug?):
            ViewThatFits(in: .horizontal) {
                minimalLine(slug: slug)
                minimalTitle
            }
        case (nil, nil):
            minimalTitle
        }
    }

    private func minimalLine(tag: String? = nil, slug: String? = nil) -> some View {
        HStack(spacing: 6) {
            minimalTitle
            if let tag {
                MetadataPill(title: tag)
            }
            if let slug {
                Text("/\(slug)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
    }

    private var minimalTitle: some View {
        HStack(spacing: 4) {
            if result.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            if result.isPinnedAudibleTab || result.hasMediaIndicator {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            Text(result.title)
                .font(.system(size: 13, weight: .semibold, design: .default))
                .foregroundStyle(result.isDiscarded ? .tertiary : .primary)
                .lineLimit(1)
        }
    }
}

private struct MetadataPill: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String

    var body: some View {
        Text(title)
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                Capsule(style: .continuous)
                    .fill(.regularMaterial)
                    .overlay(
                        Capsule(style: .continuous)
                            .fill(metadataPillTint)
                    )
            )
    }

    private var metadataPillTint: Color {
        colorScheme == .dark ? Color.white.opacity(0.09) : Color.black.opacity(0.06)
    }
}

/// Leading icon for a result row. When the result has a real favicon, it's
/// the main icon (top-left) and the source browser's icon shrinks to a small
/// badge overlapping its bottom-right corner, so the two icons don't get
/// confused for one another. When there's no favicon (e.g. Finder results),
/// only the single fallback icon is shown, with no badge.
struct LeadingIconColumn: View {
    static let iconSize: CGFloat = 16
    static let badgeHaloSize: CGFloat = 13
    static let badgeOffset: CGFloat = 4

    let browserName: String
    let fallbackSymbol: String
    let faviconImage: NSImage?

    var body: some View {
        LeadingResultIcon(browserName: browserName, fallbackSymbol: fallbackSymbol, faviconImage: faviconImage)
            .frame(width: Self.iconSize, height: Self.iconSize)
            .overlay(alignment: .bottomTrailing) {
                if faviconImage != nil {
                    BrowserBadge(browserName: browserName, size: Self.badgeHaloSize - 3)
                        .frame(width: Self.badgeHaloSize, height: Self.badgeHaloSize)
                        .background(Circle().fill(.regularMaterial))
                        .offset(x: Self.badgeOffset, y: Self.badgeOffset)
                }
            }
    }
}

struct BrowserBadge: View {
    let browserName: String
    var size: CGFloat = 14

    var body: some View {
        if let appIcon = BrowserIconCache.icon(for: browserName, size: size) {
            Image(nsImage: appIcon)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: size, height: size)
        } else {
            Image(systemName: "globe")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
        }
    }
}

struct LeadingResultIcon: View {
    let browserName: String
    let fallbackSymbol: String
    let faviconImage: NSImage?

    var body: some View {
        if let faviconImage {
            Image(nsImage: faviconImage)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
        } else if let appIcon = BrowserIconCache.icon(for: browserName, size: 16) {
            Image(nsImage: appIcon)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
        } else {
            Image(systemName: fallbackSymbol)
                .foregroundStyle(.secondary)
        }
    }
}

@MainActor
enum BrowserIconCache {
    private static let appPathByName: [String: String] = [
        "Google Chrome": "/Applications/Google Chrome.app",
        "Microsoft Edge": "/Applications/Microsoft Edge.app",
        "Brave Browser": "/Applications/Brave Browser.app",
        "Safari": "/Applications/Safari.app",
        "Finder": "/System/Library/CoreServices/Finder.app"
    ]

    private static var iconStore: [String: NSImage] = [:]

    static func icon(for browserName: String, size: CGFloat) -> NSImage? {
        let key = "\(browserName)@\(Int(size))"
        if let cached = iconStore[key] { return cached }

        guard let appPath = appPathByName[browserName],
              FileManager.default.fileExists(atPath: appPath) else {
            return nil
        }

        let icon = NSWorkspace.shared.icon(forFile: appPath)
        let sized = icon.copy() as? NSImage ?? icon
        sized.size = NSSize(width: size, height: size)
        iconStore[key] = sized
        return sized
    }
}

struct CommandBarToast: View {
    let message: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)

            Text(message)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            Capsule(style: .continuous)
                .fill(.regularMaterial)
                .shadow(color: Color.black.opacity(0.18), radius: 18, y: 10)
        )
    }
}
