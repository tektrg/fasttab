import SwiftUI

/// One labelled builder row (see `SavedViewFormRowLayout`).
public struct SavedViewFormRow<Content: View>: View {
    /// Label column width when beside the field.
    public static var labelWidth: CGFloat { 86 }
    /// Narrower than this (the edge-anchored bar), labels go above their
    /// fields so every field gets the full width.
    public static var stackedLabelsBelowWidth: CGFloat { 360 }

    let label: String
    let content: Content

    public init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    public var body: some View {
        SavedViewFormRowLayout(labelWidth: Self.labelWidth, stackBelowWidth: Self.stackedLabelsBelowWidth) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            VStack(alignment: .leading, spacing: 4) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Red caption under a field with a problem.
public struct SavedViewIssueText: View {
    let message: String
    public init(_ message: String) { self.message = message }
    public var body: some View {
        Text(message)
            .font(.caption2)
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Toggle chip (types, profiles, sections).
public struct SavedViewChip: View {
    let title: String
    let systemImage: String?
    let isOn: Bool
    let action: () -> Void

    public init(title: String, systemImage: String?, isOn: Bool, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.isOn = isOn
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 10, weight: .semibold))
                }
                Text(title)
                    .lineLimit(1)
            }
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(isOn ? Color.accentColor : Color.primary.opacity(0.8))
            .background(Capsule().fill(isOn ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.06)))
            .overlay(Capsule().strokeBorder(isOn ? Color.accentColor.opacity(0.55) : Color.primary.opacity(0.12), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// Left-aligned wrapping row (icon grid, chips).
public struct SavedViewFlowLayout: Layout {
    public var spacing: CGFloat

    public init(spacing: CGFloat = 6) { self.spacing = spacing }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews: subviews, width: proposal.width ?? .infinity)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width.map { min($0, width) } ?? width, height: height)
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews: subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

/// One labelled form row: label (trailing-aligned, fixed width) beside the
/// field when the row is at least `stackBelowWidth` wide, label above the
/// field otherwise — so the narrow edge-anchored bar gives every field its
/// full width instead of overflowing. First subview = label, second = field.
public struct SavedViewFormRowLayout: Layout {
    public var labelWidth: CGFloat
    public var stackBelowWidth: CGFloat
    public var spacing: CGFloat
    public var stackedSpacing: CGFloat

    public init(labelWidth: CGFloat, stackBelowWidth: CGFloat, spacing: CGFloat = 10, stackedSpacing: CGFloat = 3) {
        self.labelWidth = labelWidth
        self.stackBelowWidth = stackBelowWidth
        self.spacing = spacing
        self.stackedSpacing = stackedSpacing
    }

    public func isStacked(width: CGFloat?) -> Bool {
        (width ?? .infinity) < stackBelowWidth
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        let frames = arrange(width: proposal.width, subviews: subviews)
        let width = proposal.width ?? max(frames.label.maxX, frames.content.maxX)
        return CGSize(width: width, height: max(frames.label.maxY, frames.content.maxY))
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let frames = arrange(width: bounds.width, subviews: subviews)
        for (index, frame) in [frames.label, frames.content].enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(width: frame.width, height: frame.height)
            )
        }
    }

    private func arrange(width: CGFloat?, subviews: Subviews) -> (label: CGRect, content: CGRect) {
        let label = subviews[0], content = subviews[1]
        if isStacked(width: width) {
            let labelSize = label.sizeThatFits(ProposedViewSize(width: width, height: nil))
            let contentProposal = ProposedViewSize(width: width, height: nil)
            let contentSize = content.sizeThatFits(contentProposal)
            return (
                CGRect(origin: .zero, size: labelSize),
                CGRect(x: 0, y: labelSize.height + stackedSpacing,
                       width: width ?? contentSize.width, height: contentSize.height)
            )
        }
        let contentWidth = width.map { max(0, $0 - labelWidth - spacing) }
        let labelProposal = ProposedViewSize(width: labelWidth, height: nil)
        let contentProposal = ProposedViewSize(width: contentWidth, height: nil)
        let labelSize = label.sizeThatFits(labelProposal)
        let contentSize = content.sizeThatFits(contentProposal)
        // Line the label's text up with the field's first line; capped so a
        // field with no text (the icon grid) keeps its label near the top.
        let labelBaseline = label.dimensions(in: labelProposal)[VerticalAlignment.firstTextBaseline]
        let contentBaseline = content.dimensions(in: contentProposal)[VerticalAlignment.firstTextBaseline]
        let shift = min(max(contentBaseline - labelBaseline, -labelSize.height), 6)
        return (
            CGRect(x: labelWidth - min(labelSize.width, labelWidth), y: max(shift, 0),
                   width: min(labelSize.width, labelWidth), height: labelSize.height),
            CGRect(x: labelWidth + spacing, y: max(-shift, 0),
                   width: contentWidth ?? contentSize.width, height: contentSize.height)
        )
    }
}
