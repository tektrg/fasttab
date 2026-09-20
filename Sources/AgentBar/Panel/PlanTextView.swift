import SwiftUI

/// The plan on the plan card: the plan file drawn as Markdown (the same renderer as the agent's last
/// message), or, when the file cannot be shown, why, without ever blocking the answer below it.
struct PlanTextView: View {
    let file: PlanFile
    /// The path as the box drew it, shown so the user knows which file this is.
    let path: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("PLAN")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                if let path {
                    Text(path)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .textSelection(.enabled)
                }
            }
            content
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.red.opacity(0.35)))
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var content: some View {
        switch file {
        case .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Reading the plan…")
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
        case .noPath:
            note("The terminal does not name the plan file, so it cannot be shown here. Read it in the terminal; you can still answer below.")
        case .unreadable(let reason):
            note("The plan cannot be shown here. \(reason) You can still answer below.")
        case .text(let text, let truncated):
            MarkdownBlocksView(blocks: MarkdownParser.parse(text))
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .id(text)
            if truncated {
                note("The plan is longer than \(PlanFileReader.maxBytes / 1024) KB: the rest is not shown. Read it in the terminal.")
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(WarningTextColor.color)
            .fixedSize(horizontal: false, vertical: true)
    }
}
