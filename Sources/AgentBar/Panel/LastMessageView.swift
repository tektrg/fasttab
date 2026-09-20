import SwiftUI

/// The agent's latest message on the answer and permission cards, drawn as markdown. Collapsed it
/// is at most `collapsedHeight` (about five lines, the old line limit) with Show more when the
/// drawn message is taller, so it never takes the room the question needs.
struct LastMessageView: View {
    let text: String
    private let blocks: [MarkdownBlock]
    @State private var isExpanded = false
    @State private var naturalHeight: CGFloat = 0

    /// About five lines of 12pt text.
    static let collapsedHeight: CGFloat = 80

    init(text: String) {
        self.text = text
        self.blocks = MarkdownParser.parse(text)
    }

    private var isCut: Bool { !isExpanded && naturalHeight > Self.collapsedHeight }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("LAST MESSAGE")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
            MarkdownBlocksView(blocks: blocks)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .onContentHeightChange { naturalHeight = $0 }
                .frame(maxHeight: isExpanded ? nil : Self.collapsedHeight, alignment: .top)
                .mask { fadeOut }
                .clipped()
                .textSelection(.enabled)
            if naturalHeight > Self.collapsedHeight {
                Button(isExpanded ? "Show less" : "Show more") { isExpanded.toggle() }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
        .id(text)
    }

    /// A cut-off message fades at its bottom edge instead of slicing a line in half.
    @ViewBuilder
    private var fadeOut: some View {
        if isCut {
            LinearGradient(stops: [.init(color: .black, location: 0.7), .init(color: .clear, location: 1)],
                           startPoint: .top, endPoint: .bottom)
        } else {
            Color.black
        }
    }
}
