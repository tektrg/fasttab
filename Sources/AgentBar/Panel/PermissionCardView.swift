import SwiftUI

/// The permission card: replaces the list while an agent's permission box is open. Top to
/// bottom: who, what the agent last said, the tool and the exact command or file it wants
/// (in full, monospaced, selectable), the choices, then the action bar. Fills exactly
/// `bodyHeight`, the height of the list it replaces. Keys are handled by the search field
/// (see `SearchFieldView`).
struct PermissionCardView: View {
    @ObservedObject var permission: PermissionCardModel
    let bodyHeight: CGFloat

    var body: some View {
        if let card = permission.card {
            VStack(alignment: .leading, spacing: 0) {
                header(card)
                scrollingBody(card)
                bottomBar(card)
            }
            .frame(height: bodyHeight)
        }
    }

    // MARK: - Sections

    private func header(_ card: PermissionCard) -> some View {
        HStack(spacing: 8) {
            Text(card.label)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)
            if let project = card.projectName {
                Text(project)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .frame(height: AgentPanelMetrics.answerHeaderHeight)
    }

    @ViewBuilder
    private func messageSection(_ card: PermissionCard) -> some View {
        switch card.message {
        case .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Reading the agent's last message…")
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 18)
            .padding(.bottom, 8)
        case .text(let text):
            LastMessageView(text: text)
        case .none:
            EmptyView()
        }
    }

    /// Everything between the header and the action bar scrolls together, so a long command is
    /// shown whole instead of being cut.
    private func scrollingBody(_ card: PermissionCard) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                messageSection(card)
                request(card.state.prompt)
                if let note = card.state.changedNote { noteLine(note) }
                choicesSection(card.state)
            }
            .padding(.bottom, 8)
        }
    }

    /// What is being asked for: the tool, and the exact command / file / detail. An edit box
    /// shows the file first, then its diff excerpt; everything is shown whole.
    private func request(_ prompt: PermissionPrompt) -> some View {
        let parts = prompt.detailParts
        return VStack(alignment: .leading, spacing: 6) {
            Text(prompt.isFileEdit ? "EDIT TO A FILE (\(prompt.tool.uppercased())) NEEDS YOUR OK" : "\(prompt.tool.uppercased()) NEEDS YOUR OK")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                Text(parts.headline.isEmpty ? "(no details shown)" : parts.headline)
                    .font(.system(size: 13, weight: prompt.isFileEdit ? .semibold : .regular, design: .monospaced))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let diff = parts.body {
                    Text(diff)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .textSelection(.enabled)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.red.opacity(0.35)))
            Text(prompt.title)
                .font(.system(size: 15, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func noteLine(_ note: String) -> some View {
        Text(note)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 18)
            .padding(.bottom, 6)
    }

    @ViewBuilder
    private func choicesSection(_ state: PermissionCardState) -> some View {
        switch state.phase {
        case .checking:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Checking the terminal's prompt before you decide…")
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 18)
            .padding(.top, 4)
        case .unavailable(let reason):
            Text(reason)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 18)
                .padding(.top, 4)
        case .ready:
            VStack(spacing: 2) {
                ForEach(state.choices, id: \.self) { choice in
                    choiceRow(choice, state: state)
                }
            }
            .padding(.horizontal, 6)
        }
    }

    private func choiceRow(_ choice: PermissionChoice, state: PermissionCardState) -> some View {
        let isHighlighted = state.highlighted == choice
        let option = state.prompt.option(for: choice)
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(option.map { "\($0.index)" } ?? "")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(choice.title)
                    .font(.system(size: 14, weight: .semibold))
                if let label = option?.label {
                    Text(label)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(isHighlighted ? Color.accentColor.opacity(0.22) : .clear))
        .contentShape(Rectangle())
        .onTapGesture { permission.clickChoice(choice) }
    }

    private func bottomBar(_ card: PermissionCard) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if card.state.isConfirmingAlways { confirmAlwaysLine(card.state) }
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                switch card.state.phase {
                case .unavailable:
                    Button("Open terminal") { permission.openTerminal() }
                case .checking, .ready:
                    Button(card.state.actionTitle) { permission.pressSend() }
                        .disabled(!card.state.canSend)
                        .tint(card.state.isConfirmingAlways ? .red : nil)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 6)
        .frame(minHeight: AgentPanelMetrics.answerBottomBarHeight)
        .background(Color.primary.opacity(0.04))
    }

    /// What "Allow always" would allow for good, in the box's own words, next to the command.
    private func confirmAlwaysLine(_ state: PermissionCardState) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Always allow \(state.prompt.tool): \(state.highlightedOptionLabel ?? "")")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
            Text(state.prompt.detail)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .truncationMode(.middle)
        }
    }
}
