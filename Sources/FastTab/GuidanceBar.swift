import SwiftUI
import IndieCommandBar

typealias LastInteractionKey = CommandBarLastInteraction

/// Fast Tab's footer hint line: IndieCommandBar's `CommandBarGuidanceBar`
/// with Fast Tab's status line (tab count, duplicates tag, or the hovered
/// row's metadata in Minimal style).
struct GuidanceBarView: View {
    let hint: GuidanceHint
    let statusText: String?
    var duplicateTabCount: Int = 0
    var onTapDuplicateTag: (() -> Void)? = nil
    /// Hovered row's result, Minimal row style only (nil otherwise).
    var hoveredResult: BrowserSearchResult? = nil
    var showWindowName: Bool = false
    var showProfileName: Bool = false

    @Environment(\.isCompactCommandBar) private var isCompact

    var body: some View {
        CommandBarGuidanceBar(hint: hint) {
            if let hoveredResult {
                HoveredResultMetadataRow(
                    result: hoveredResult,
                    showWindowName: showWindowName,
                    showProfileName: showProfileName
                )
            } else if statusText != nil || duplicateTabCount > 0 {
                HStack(spacing: 6) {
                    if let statusText {
                        Text(statusText)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(isCompact ? 2 : 1)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if duplicateTabCount > 0, let onTapDuplicateTag {
                        DuplicateTabCountTag(count: duplicateTabCount, action: onTapDuplicateTag)
                    }
                }
            }
        }
    }
}

/// Hovered row's type icon, recency, window/profile, and URL — the same
/// metadata Full row style shows inline, surfaced here because Minimal rows
/// drop it to stay one line.
private struct HoveredResultMetadataRow: View {
    let result: BrowserSearchResult
    let showWindowName: Bool
    let showProfileName: Bool

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: result.type.symbolName)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
                .layoutPriority(1)

            if let recency = result.relativeRecencyLabel {
                Text(recency)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .layoutPriority(1)
            }

            ForEach(result.secondaryMetadata(showWindowName: showWindowName, showProfileName: showProfileName), id: \.self) { metadata in
                Text(metadata)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .layoutPriority(1)
            }

            // Truncates instead of wrapping to a second line — the row that
            // hosts this is a single fixed-height footer line, so a long URL
            // has to give up its own tail rather than growing the footer.
            Text(result.secondaryBaseText)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Tappable pill next to the tab-count status text. Clicking it applies the
/// same `@duplicate` filter as picking "Duplicate" from the `@` menu.
private struct DuplicateTabCountTag: View {
    let count: Int
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text("\(count) \(count == 1 ? "duplicate" : "duplicates")")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.orange)
                .lineLimit(1)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.orange.opacity(isHovering ? 0.22 : 0.14))
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}
