import SwiftUI

/// The ⌘K keyboard menu (`RowKeyMenu`): the agent's answer options (if it waits on a question), a
/// divider, then the row's ⋯ items — numbered through both, the highlighted one tinted. Floats over the
/// bottom-right of the list, above the search box. Labels never wrap; long answer labels truncate (full in help).
struct RowKeyMenuView: View {
    let menu: RowKeyMenu
    let agentLabel: String
    let onChoose: (Int) -> Void

    static let answerLabelMaxWidth: CGFloat = 300

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            let answers = menu.answerCount
            sectionTitle(answers > 0 ? "Answer · \(agentLabel)" : "Actions · \(agentLabel)")
            ForEach(Array(menu.entries.enumerated()), id: \.offset) { index, entry in
                if answers > 0, index == answers {
                    Divider().padding(.horizontal, 8).padding(.vertical, 3)
                    sectionTitle("Actions")
                }
                row(index: index, entry: entry)
            }
            Text("↑↓ move · ↩ choose · 1–9 pick · esc close")
                .font(.avenir(size: 10))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 10).padding(.vertical, 4)
        }
        .padding(4)
        .fixedSize()
        .background(RoundedRectangle(cornerRadius: 10).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.12)))
        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.avenir(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: Self.answerLabelMaxWidth, alignment: .leading)
            .padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 2)
    }

    private func row(index: Int, entry: RowKeyMenu.Entry) -> some View {
        let isOn = index == menu.highlighted
        return Button { onChoose(index) } label: {
            HStack(spacing: 10) {
                Text(RowKeyMenu.number(at: index) ?? " ")
                    .font(.avenirMono(size: 11, weight: .semibold))
                    .foregroundStyle(isOn ? Color.white.opacity(0.9) : .secondary)
                    .frame(width: 12)
                label(entry)
                Spacer(minLength: 16)
            }
            .foregroundStyle(isOn ? Color.white : (entry.isEnabled ? Color.primary : Color.secondary))
            .padding(.horizontal, 10)
            .frame(minWidth: 200, minHeight: 26, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(isOn ? Color.accentColor : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!entry.isEnabled)
        .help(entry.help)
    }

    @ViewBuilder
    private func label(_ entry: RowKeyMenu.Entry) -> some View {
        let text = Text(entry.label).font(.avenir(size: 13, weight: .medium)).lineLimit(1)
        if case .option = entry {
            text.truncationMode(.tail).frame(maxWidth: Self.answerLabelMaxWidth, alignment: .leading)
        } else {
            text.fixedSize()
        }
    }
}
