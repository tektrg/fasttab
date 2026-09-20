import SwiftUI

/// Draws parsed markdown blocks at the card's message size (12pt). Native SwiftUI: prose is
/// `Text`, code a monospaced tile, tables a `Grid`. Selection is left to the owner
/// (`.textSelection` on the container reaches every `Text` inside).
struct MarkdownBlocksView: View {
    let blocks: [MarkdownBlock]

    private static let bodySize: CGFloat = 12

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(Self.styled(text))
                .font(.system(size: Self.headingSize(level), weight: .semibold))
                .padding(.top, 3)
                .proseLayout()
        case .paragraph(let text):
            Text(Self.styled(text))
                .font(.system(size: Self.bodySize))
                .proseLayout()
        case .listItem(let depth, let marker, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(Self.markerText(marker))
                    .font(.system(size: Self.bodySize, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text(Self.styled(text))
                    .font(.system(size: Self.bodySize))
                    .proseLayout()
            }
            .padding(.leading, CGFloat(min(depth, 5)) * 16)
        case .codeBlock(let language, let code):
            codeTile(language: language, code: code)
        case .quote(let inner):
            MarkdownBlocksView(blocks: inner)
                .foregroundStyle(.secondary)
                .padding(.leading, 11)
                .overlay(alignment: .leading) {   // an overlay, so the bar is as tall as the text and no taller
                    RoundedRectangle(cornerRadius: 1.5).fill(Color.secondary.opacity(0.5)).frame(width: 3)
                }
        case .table(let header, let rows):
            tableGrid(header: header, rows: rows)
        case .rule:
            Divider().padding(.vertical, 2)
        }
    }

    private func codeTile(language: String?, code: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if let language {
                Text(language)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            Text(verbatim: code)
                .font(.system(size: 11, design: .monospaced))
                .proseLayout()
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.07)))
    }

    /// Columns share the card's width; long cells wrap.
    private func tableGrid(header: [String], rows: [[String]]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
            GridRow(alignment: .firstTextBaseline) {
                ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                    tableCell(cell).fontWeight(.semibold)
                }
            }
            Divider().gridCellUnsizedAxes(.horizontal)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow(alignment: .firstTextBaseline) {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, cell in tableCell(cell) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func tableCell(_ text: String) -> some View {
        Text(Self.styled(text))
            .font(.system(size: Self.bodySize))
            .fixedSize(horizontal: false, vertical: true)
    }

    private static func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: 15
        case 2: 14
        case 3: 13
        default: 12
        }
    }

    private static func markerText(_ marker: MarkdownBlock.ListMarker) -> String {
        switch marker {
        case .bullet: "•"
        case .number(let number): "\(number)."
        }
    }

    /// Inline markdown, with code spans given a faint tile (the font comes from the code intent).
    static func styled(_ text: String) -> AttributedString {
        var result = MarkdownInline.attributed(text)
        for run in Array(result.runs) where run.inlinePresentationIntent?.contains(.code) == true {
            result[run.range].backgroundColor = Color.primary.opacity(0.1)
        }
        return result
    }
}

private extension View {
    /// Wraps to the width it is given and takes as many lines as it needs.
    func proseLayout() -> some View {
        frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
    }
}
