import SwiftUI

enum LastInteractionKey: Equatable {
    case none, upDown, space, leftRight
}

struct GuidanceToken: Equatable, Hashable {
    let glyph: String
    let label: String
}

struct GuidanceHint: Equatable, Hashable {
    let tokens: [GuidanceToken]

    static let empty = GuidanceHint(tokens: [])

    var isEmpty: Bool { tokens.isEmpty }
}

struct GuidanceBarView: View {
    let hint: GuidanceHint
    let statusText: String?

    @Environment(\.isCompactCommandBar) private var isCompact

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let statusText {
                Text(statusText)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(isCompact ? 2 : 1)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !hint.isEmpty {
                // Wraps instead of clipping: the half-width edge surface can't
                // fit every hint token on one row.
                WrappingHStack(horizontalSpacing: 8, verticalSpacing: 5) {
                    ForEach(Array(hint.tokens.enumerated()), id: \.offset) { _, token in
                        HStack(spacing: 3) {
                            Text(token.glyph)
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 2)
                                .background(
                                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                                        .fill(.quaternary)
                                )
                            Text(token.label)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .id(hint)
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: hint)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Left-to-right flow layout that moves to a new row when the next subview
/// would overflow the proposed width. Used for content that must stay fully
/// readable at the narrow (half-width) edge-anchored surface size rather than
/// truncating.
struct WrappingHStack: Layout {
    var horizontalSpacing: CGFloat = 8
    var verticalSpacing: CGFloat = 5

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = layoutRows(maxWidth: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +)
            + verticalSpacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
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

/// True when the command bar is rendering at the narrow, half-width
/// edge-anchored size — content should wrap rather than truncate.
private struct IsCompactCommandBarKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var isCompactCommandBar: Bool {
        get { self[IsCompactCommandBarKey.self] }
        set { self[IsCompactCommandBarKey.self] = newValue }
    }
}
