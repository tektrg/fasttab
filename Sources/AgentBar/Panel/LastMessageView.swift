import SwiftUI

/// The agent's latest message on the answer and permission cards, drawn as markdown. Collapsed it
/// is at most `collapsedHeight` (about five lines) with Show more when shown on its own; inside the
/// "Last message" fold (`showsTitle == false`) the fold is the toggle, so no Show more — it scrolls past `foldMaxHeight`.
struct LastMessageView: View {
    let text: String
    /// False when a fold above already carries the "Last message" title (`LastMessageSection`).
    var showsTitle = true
    private let blocks: [MarkdownBlock]
    @State private var isExpanded = false
    @State private var naturalHeight: CGFloat = 0

    /// About five lines of 12pt text.
    static let collapsedHeight: CGFloat = 80

    init(text: String, showsTitle: Bool = true) {
        self.text = text
        self.showsTitle = showsTitle
        self.blocks = MarkdownParser.parse(text)
    }

    /// The tallest the message gets inside the fold before it scrolls (about 15 lines).
    static let foldMaxHeight: CGFloat = 240

    private var message: some View {
        MarkdownBlocksView(blocks: blocks)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    /// Standalone (Space-peek): at most `collapsedHeight` with Show more.
    @ViewBuilder
    private var cappedMessage: some View {
        message
            .onContentHeightChange { naturalHeight = $0 }
            .frame(maxHeight: isExpanded ? nil : Self.collapsedHeight, alignment: .top)
            .mask { fadeOut }
            .clipped()
        if naturalHeight > Self.collapsedHeight {
            Button(isExpanded ? "Show less" : "Show more") { isExpanded.toggle() }
                .buttonStyle(.link)
                .font(.avenir(size: 11))
        }
    }

    private var isCut: Bool { !isExpanded && naturalHeight > Self.collapsedHeight }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if showsTitle {
                Text("LAST MESSAGE")
                    .font(.avenir(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            if showsTitle {
                cappedMessage
            } else {
                // Inside the "Last message" fold the fold is the toggle: the whole message, scrolling
                // past `foldMaxHeight` instead of a second Show more.
                ScrollView {
                    message.onContentHeightChange { naturalHeight = $0 }
                }
                .frame(height: min(max(naturalHeight, 1), Self.foldMaxHeight))
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
