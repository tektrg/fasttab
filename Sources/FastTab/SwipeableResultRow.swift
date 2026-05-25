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
        case .delete: return .red
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
    static let actionIconSize: CGFloat = 30
    static let actionIconInset: CGFloat = 8
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
    let onCopyLink: () -> Void
    let onRemove: () -> Void
    let onHoverChange: (Bool) -> Void

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
        let minimumSpace = ResultSwipeMetrics.actionIconSize + (ResultSwipeMetrics.actionIconInset * 2)
        guard visibleSpace >= minimumSpace else { return 0 }

        let progress = (visibleSpace - minimumSpace) / (ResultSwipeMetrics.revealDistance - minimumSpace)
        return min(1, max(0, Double(progress)))
    }

    var body: some View {
        ZStack {
            ResultRowView(
                result: result,
                isSelected: isSelected,
                faviconImage: faviconImage,
                showWindowName: showWindowName,
                showProfileName: showProfileName,
                onCopyLink: onCopyLink,
                onRemove: onRemove
            )
            .offset(x: visibleOffset)
            .animation(.spring(response: 0.24, dampingFraction: 0.88), value: keyboardAction)
            .animation(.spring(response: 0.24, dampingFraction: 0.88), value: pointerAction)

            if let visibleAction {
                TailSwipeActionIcon(action: visibleAction)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: visibleAction.tailAlignment)
                    .padding(.horizontal, ResultSwipeMetrics.actionIconInset)
                    .opacity(tailIconOpacity)
                    .scaleEffect(0.86 + (0.14 * CGFloat(tailIconOpacity)))
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

    var body: some View {
        Image(systemName: action.iconName)
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: ResultSwipeMetrics.actionIconSize, height: ResultSwipeMetrics.actionIconSize)
            .background(
                Circle()
                    .fill(action.tint)
                    .shadow(color: action.tint.opacity(0.28), radius: 8, y: 3)
            )
    }
}

private struct ResultRowView: View {
    let result: BrowserSearchResult
    let isSelected: Bool
    let faviconImage: NSImage?
    let showWindowName: Bool
    let showProfileName: Bool
    let onCopyLink: () -> Void
    let onRemove: () -> Void

    private var secondaryMetadata: [String] {
        result.secondaryMetadata(showWindowName: showWindowName, showProfileName: showProfileName)
    }

    var body: some View {
        HStack(spacing: 10) {
            LeadingResultIcon(browserName: result.browserName, fallbackSymbol: result.type.symbolName, faviconImage: faviconImage)
                .frame(width: 16, height: 16)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    if result.hasMediaIndicator {
                        Image(systemName: "speaker.wave.2.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }

                    Text(result.title)
                        .font(.system(size: 13, weight: .semibold, design: .default))
                        .lineLimit(1)
                }

                HStack(spacing: 5) {
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
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                BrowserBadge(browserName: result.browserName)

                Menu {
                    Button("Copy Link", action: onCopyLink)
                    Divider()
                    if result.type == .tab {
                        Button("Close Tab", action: onRemove)
                    } else {
                        Button("Delete", role: .destructive, action: onRemove)
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .buttonStyle(.plain)
            }
        }
        .opacity(result.type.dimmingOpacity)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
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

private struct BrowserBadge: View {
    let browserName: String

    var body: some View {
        Group {
            if let appIcon = BrowserIconCache.icon(for: browserName, size: 14) {
                Image(nsImage: appIcon)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 14, height: 14)
            } else {
                Image(systemName: "globe")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 22, height: 22)
    }
}

private struct LeadingResultIcon: View {
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
private enum BrowserIconCache {
    private static let appPathByName: [String: String] = [
        "Google Chrome": "/Applications/Google Chrome.app",
        "Microsoft Edge": "/Applications/Microsoft Edge.app"
    ]

    private static var iconStore: [String: NSImage] = [:]

    static func icon(for browserName: String, size: CGFloat) -> NSImage? {
        if let cached = iconStore[browserName] {
            let icon = cached.copy() as? NSImage ?? cached
            icon.size = NSSize(width: size, height: size)
            return icon
        }

        guard let appPath = appPathByName[browserName],
              FileManager.default.fileExists(atPath: appPath) else {
            return nil
        }

        let icon = NSWorkspace.shared.icon(forFile: appPath)
        iconStore[browserName] = icon

        let sized = icon.copy() as? NSImage ?? icon
        sized.size = NSSize(width: size, height: size)
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
