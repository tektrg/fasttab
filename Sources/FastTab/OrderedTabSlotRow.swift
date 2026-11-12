import SwiftUI
import AppKit
import IndieCommandBar

struct OrderedTabSlotRow: View {
    @Environment(\.commandBarTheme) private var theme
    let slot: OrderedTabSlot
    let index: Int
    let isSelected: Bool
    let faviconImage: NSImage?
    let onSelect: () -> Void
    let onClose: () -> Void
    let onReopen: () -> Void
    let onTogglePin: () -> Void
    let onReorder: (Int, Int) -> Void
    /// Upper bound (exclusive) for drag-reorder targets. The Stack view only
    /// shows pinned slots, so dragging must stay inside the pinned prefix —
    /// otherwise a row dragged past the section would silently unpin itself.
    /// Defaults to the full store count.
    var reorderUpperBound: Int? = nil
    /// "Send to FastTab List & Close"; offered only on live web tabs (see `forStackSlot`).
    var onSendToFastTabList: (() -> Void)? = nil
    /// ⋯ › Copy URL (same action as ⌘C).
    var onCopy: () -> Void = {}

    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(CommandBarAppearance.resultRowStyleKey) private var rowStyle: ResultRowStyle = .minimal
    @ObservedObject private var myOrderStore = MyOrderStore.shared
    @State private var isHovering = false
    @State private var dragOffset: CGFloat = 0
    @State private var isActivelyDragging = false

    private var isGhost: Bool { slot.state == .ghost }
    private var isFrozen: Bool { slot.state == .browserFrozen }

    private var isActionsVisible: Bool { isHovering || isSelected }

    /// Trailing clearance reserved while the action menu is visible, so the
    /// title truncates before the trigger instead of running underneath it.
    /// Full style reserves nothing: the overlay covers the text, so hover never re-wraps it.
    private var actionReserveWidth: CGFloat {
        guard rowStyle == .minimal, isActionsVisible else { return 0 }
        return RowActionOverlay<EmptyView>.reservedWidth(
            buttonCount: 2,
            leadingFadeWidth: 0,
            trailingPadding: 0
        )
    }

    var body: some View {
        Button(action: {
            if isGhost {
                onReopen()
            } else {
                onSelect()
            }
        }) {
            HStack(spacing: 10) {
                // Favicon / Browser icon with drag handle overlay on hover
                LeadingIconColumn(
                    browserName: slot.browserName,
                    fallbackSymbol: isGhost ? "clock.arrow.circlepath" : "globe",
                    faviconImage: faviconImage
                )
                .opacity(isGhost ? 0.5 : 1.0)
                .overlay {
                    if isHovering || isActivelyDragging {
                        Image(systemName: "line.3.horizontal")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: LeadingIconColumn.iconSize + 6, height: LeadingIconColumn.iconSize + 6)
                            .background(solidLeadingBackground)
                            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                            .transition(.opacity)
                    }
                }

                // Title & metadata
                VStack(alignment: .leading, spacing: rowStyle == .minimal ? 0 : 3) {
                    HStack(spacing: 6) {
                        if slot.isPinned {
                            Image(systemName: "pin.fill")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }

                        HoverMarqueeText(slot.title.isEmpty ? slot.url : slot.title)
                            .font(.system(size: 13, weight: .regular, design: .default))
                            .foregroundStyle(titleColor)

                        if isFrozen {
                            Text("\(slot.browserName) closed")
                                .font(.system(size: 9, weight: .medium, design: .rounded))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(
                                    Capsule().fill(Color.orange.opacity(0.18))
                                )
                                .foregroundStyle(.orange)
                        }
                    }

                    if rowStyle == .full {
                        HStack(spacing: 6) {
                            Text(slot.browserName)
                                .font(.caption2)
                                .foregroundStyle(.secondary)

                            if let prof = slot.profileName, !prof.isEmpty {
                                Text(prof)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }

                            Text(displayHost(from: slot.url))
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, actionReserveWidth)
                .clipped()

                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .padding(.vertical, rowStyle == .minimal ? 6 : 10)
        .overlay(alignment: .trailing) {
            RowActionOverlay(
                isSelected: isSelected,
                isHovering: isHovering,
                isVisible: isHovering || isSelected,
                leadingFadeWidth: 4,
                trailingPadding: 10
            ) {
                actionButtonCluster
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isSelected ? theme.accentColor.opacity(0.17) : (isHovering ? Color.primary.opacity(0.04) : Color.clear))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(isSelected ? theme.accentColor.opacity(0.3) : .clear, lineWidth: 1)
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .offset(y: dragOffset)
        .zIndex(isActivelyDragging ? 10 : 0)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering
        }
        .gesture(
            DragGesture(minimumDistance: 6)
                .onChanged { value in
                    isActivelyDragging = true
                    myOrderStore.isDragging = true
                    dragOffset = value.translation.height
                }
                .onEnded { value in
                    let rowHeight: CGFloat = rowStyle == .minimal ? 40.0 : 66.0
                    let slotDelta = Int((value.translation.height / rowHeight).rounded())
                    let upperBound = reorderUpperBound ?? myOrderStore.slots.count
                    let targetIndex = min(max(0, index + slotDelta), max(0, upperBound - 1))
                    dragOffset = 0
                    isActivelyDragging = false
                    myOrderStore.isDragging = false
                    if targetIndex != index {
                        onReorder(index, targetIndex)
                    }
                }
        )
    }

    private var solidLeadingBackground: some View {
        RowActionOverlay<EmptyView>.solidBackground(isSelected: isSelected, isHovering: isHovering)
    }

    private var titleColor: Color {
        if isGhost {
            return .secondary.opacity(0.7)
        }
        if isFrozen {
            return .secondary
        }
        return .primary
    }

    private func displayHost(from urlString: String) -> String {
        guard let url = URL(string: urlString), let host = url.host else {
            return urlString
        }
        return host
    }

    private var closeActionTitle: String {
        if isGhost { return "Remove Permanently" }
        return slot.isPinned ? "Close Tab (Keeps Ghost)" : "Close Tab"
    }

    private var menuActions: [CommandBarRowAction] {
        FastTabRowMenu.actions(
            for: slot,
            bridge: onSendToFastTabList == nil ? nil : FastTabListRowBridge.forStackSlot(slot)
        )
    }

    private func perform(_ action: CommandBarRowAction) {
        switch action.id {
        case FastTabRowMenu.openID: isGhost ? onReopen() : onSelect()
        case FastTabRowMenu.listBridgeID: onSendToFastTabList?()
        case FastTabRowMenu.pinID: onTogglePin()
        case CommandBarRowAction.copyID: onCopy()
        default: break
        }
    }

    @ViewBuilder
    private var actionButtonCluster: some View {
        RowActionMenu(actions: menuActions, font: .system(size: 11, weight: .semibold), style: .circle, onSelect: perform)
        RowCloseButton(
            keepsGhost: slot.isPinned && !isGhost,
            help: closeActionTitle,
            action: onClose
        )
    }
}
