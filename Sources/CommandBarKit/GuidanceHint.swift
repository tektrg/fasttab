import SwiftUI

/// One key hint in the guidance bar: a key glyph (`↵`, `Esc`, `⌘K`) and what
/// pressing it does.
public struct GuidanceToken: Equatable, Hashable, Sendable {
    public let glyph: String
    public let label: String

    public init(glyph: String, label: String) {
        self.glyph = glyph
        self.label = label
    }
}

public struct GuidanceHint: Equatable, Hashable, Sendable {
    public let tokens: [GuidanceToken]

    public init(tokens: [GuidanceToken]) {
        self.tokens = tokens
    }

    public static let empty = GuidanceHint(tokens: [])

    public var isEmpty: Bool { tokens.isEmpty }
}

/// Left-to-right flow layout that moves to a new row when the next subview
/// would overflow the proposed width. Used for content that must stay fully
/// readable at the narrow (half-width) edge-anchored surface size rather than
/// truncating.
public struct WrappingHStack: Layout {
    public var horizontalSpacing: CGFloat = 8
    public var verticalSpacing: CGFloat = 5

    public init(horizontalSpacing: CGFloat = 8, verticalSpacing: CGFloat = 5) {
        self.horizontalSpacing = horizontalSpacing
        self.verticalSpacing = verticalSpacing
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = layoutRows(maxWidth: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +)
            + verticalSpacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: width, height: height)
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = layoutRows(maxWidth: bounds.width, subviews: subviews)
        var y = bounds.minY

        for row in rows {
            var x = bounds.minX
            for index in row.indices {
                let size = measure(subviews[index], maxWidth: bounds.width)
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                    proposal: ProposedViewSize(size)
                )
                x += size.width + horizontalSpacing
            }
            y += row.height + verticalSpacing
        }
    }

    /// A subview's size, never wider than the row it has to fit in. Measuring
    /// with `.unspecified` alone reports a single unbroken line for text, so a
    /// long URL would report thousands of points wide and push the whole
    /// enclosing row past the surface edge instead of truncating or wrapping.
    private func measure(_ subview: LayoutSubviews.Element, maxWidth: CGFloat) -> CGSize {
        let ideal = subview.sizeThatFits(.unspecified)
        guard maxWidth.isFinite, ideal.width > maxWidth else { return ideal }
        return subview.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func layoutRows(maxWidth: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()

        for index in subviews.indices {
            let size = measure(subviews[index], maxWidth: maxWidth)
            let advance = current.indices.isEmpty ? size.width : size.width + horizontalSpacing

            if !current.indices.isEmpty, current.width + advance > maxWidth {
                rows.append(current)
                current = Row()
            }

            current.indices.append(index)
            current.width += current.indices.count == 1 ? size.width : size.width + horizontalSpacing
            current.height = max(current.height, size.height)
        }

        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
