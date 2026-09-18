import SwiftUI

struct BookmarkTreeRow: View {
    let row: BookmarkDisplayRow
    let isSelected: Bool
    let onSelect: () -> Void
    let onToggleFolder: () -> Void
    let onCopy: () -> Void
    let onRemove: () -> Void
    var onCloseTab: (() -> Void)? = nil

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            switch row {
            case .folder(_, let name, let depth, let isExpanded, let childCount, _):
                folderContent(name: name, depth: depth, isExpanded: isExpanded, childCount: childCount)
            case .bookmark(let item, let depth, let matchingLiveTab, let isArmedForDelete, let isDeleting):
                bookmarkContent(item: item, depth: depth, matchingLiveTab: matchingLiveTab, isArmedForDelete: isArmedForDelete, isDeleting: isDeleting)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.18) : (isHovered ? Color.primary.opacity(0.05) : Color.clear))
        )
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .onHover { isHovered = $0 }
    }

    @ViewBuilder
    private func folderContent(name: String, depth: Int, isExpanded: Bool, childCount: Int) -> some View {
        Button(action: onToggleFolder) {
            HStack(spacing: 6) {
                if depth > 0 {
                    Spacer().frame(width: CGFloat(depth) * 16)
                }

                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 14)

                Image(systemName: isExpanded ? "folder.fill" : "folder")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.accentColor)

                Text(name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)

                Text("(\(childCount))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func bookmarkContent(
        item: BookmarkItem,
        depth: Int,
        matchingLiveTab: BrowserSearchResult?,
        isArmedForDelete: Bool,
        isDeleting: Bool
    ) -> some View {
        Button(action: {
            if !isDeleting {
                onSelect()
            }
        }) {
            HStack(spacing: 8) {
                if depth > 0 {
                    Spacer().frame(width: CGFloat(depth) * 16 + 14)
                }

                if isDeleting {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                        .frame(width: 14, height: 14)
                } else {
                    Image(systemName: "bookmark")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(item.title)
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        if isDeleting {
                            HStack(spacing: 3) {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                    .font(.system(size: 9, weight: .semibold))
                                Text("Syncing to browser…")
                                    .font(.system(size: 10, weight: .medium))
                            }
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(
                                Capsule().fill(Color.primary.opacity(0.06))
                            )
                        } else if matchingLiveTab != nil {
                            Text("OPEN")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.green)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(
                                    Capsule().fill(Color.green.opacity(0.15))
                                )
                        }
                    }

                    Text(item.url)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDeleting)
        .opacity(isDeleting ? 0.45 : 1.0)
        .animation(.easeInOut(duration: 0.2), value: isDeleting)
        .overlay(alignment: .trailing) {
            RowActionOverlay(
                isSelected: isSelected,
                isHovering: isHovered,
                isVisible: !isDeleting && (isHovered || isSelected || isArmedForDelete),
                accentTint: Color.primary.opacity(0.05),
                trailingPadding: 0
            ) {
                actionButtonCluster(isArmedForDelete: isArmedForDelete, isOpen: matchingLiveTab != nil)
            }
        }
    }

    @ViewBuilder
    private func actionButtonCluster(isArmedForDelete: Bool, isOpen: Bool) -> some View {
        HStack(spacing: 4) {
            Button(action: onCopy) {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.primary.opacity(0.06)))
            }
            .buttonStyle(.plain)
            .help("Copy link")

                if isOpen, let onCloseTab {
                    Button(action: onCloseTab) {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(Color.primary.opacity(0.06)))
                    }
                    .buttonStyle(.plain)
                    .help("Close tab")
                }

            Button(action: onRemove) {
                if isArmedForDelete {
                    HStack(spacing: 2) {
                        Image(systemName: "trash")
                            .font(.system(size: 10, weight: .bold))
                        Text("Delete")
                            .font(.system(size: 11, weight: .bold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.red))
                } else {
                    Image(systemName: "minus")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color.primary.opacity(0.06)))
                }
            }
            .buttonStyle(.plain)
            .help(isArmedForDelete ? "Confirm delete bookmark" : "Delete bookmark")
        }
    }
}
