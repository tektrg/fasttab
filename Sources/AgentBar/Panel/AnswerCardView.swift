import SwiftUI

/// The answer card: replaces the list while an agent's question is open. Top to
/// bottom: who, what the agent last said, the question with numbered options,
/// then the Send button. Fills exactly `bodyHeight`, the height of the list it
/// replaces. Keys are handled by the search field (see `SearchFieldView`) and,
/// while typing an "Other" answer, by the text field in the option row.
struct AnswerCardView: View {
    @ObservedObject var answer: AnswerCardModel
    let bodyHeight: CGFloat
    /// The agent whose details were just copied (for the "Copied" feedback), and the copy action.
    var copiedAgentID: String?
    var onCopy: () -> Void = {}
    var onOpen: () -> Void = {}

    var body: some View {
        if let card = answer.card {
            VStack(alignment: .leading, spacing: 0) {
                header(card)
                scrollingBody(card)
                bottomBar(card)
            }
            .frame(height: bodyHeight)
        }
    }

    // MARK: - Sections

    private func header(_ card: AnswerCard) -> some View {
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
            OpenAgentButton(onOpen: onOpen)
            CopyIdentityButton(isCopied: copiedAgentID == card.agentID, showsLabel: true, onCopy: onCopy)
        }
        .padding(.horizontal, 18)
        .frame(height: AgentPanelMetrics.answerHeaderHeight)
    }

    @ViewBuilder
    private func messageSection(_ card: AnswerCard) -> some View {
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

    @ViewBuilder
    private func planLink(_ card: AnswerCard) -> some View {
        if let planFile = card.planFile {
            Button(action: { answer.openPlan() }) {
                Label("Likely plan: \(planFile.lastPathComponent)", systemImage: "doc.text")
                    .font(.system(size: 12))
                    .lineLimit(1)
            }
            .buttonStyle(.link)
            .help(planFile.path)
            .padding(.horizontal, 18)
            .padding(.bottom, 8)
        }
    }

    /// Everything between the header and the Send bar scrolls together, so a long
    /// question or long options are shown whole instead of being cut.
    private func scrollingBody(_ card: AnswerCard) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    messageSection(card)
                    planLink(card)
                    if let form = card.form {
                        AnswerFormView(answer: answer, form: form)
                    } else {
                        questionHeading(card.state.question)
                        options(card)
                    }
                }
                .padding(.bottom, 8)
            }
            .onChange(of: card.state.highlightedPosition) {
                proxy.scrollTo(card.state.highlightedOption.index)
            }
            .onChange(of: card.state.phase) {
                proxy.scrollTo(card.state.highlightedOption.index)
            }
        }
    }

    private func questionHeading(_ question: AnswerableQuestion) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(question.title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(question.displayQuestion)
                .font(.system(size: 15, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func options(_ card: AnswerCard) -> some View {
        VStack(spacing: 2) {
            ForEach(Array(card.state.question.options.enumerated()), id: \.element.index) { position, option in
                AnswerOptionRowView(
                    option: option,
                    isMultiSelect: card.state.question.isMultiSelect,
                    isHighlighted: position == card.state.highlightedPosition,
                    isChecked: card.state.isChecked(option),
                    isTypingHere: option.isOther && card.state.phase == .typingOther,
                    typedTextNote: card.state.otherTextNote,
                    otherText: Binding(get: { card.state.otherText }, set: { answer.setOtherText($0) }),
                    onSubmitText: { answer.handle(.enter) },
                    onLeaveText: { answer.handle(.escape) },
                    onLeaveTextUp: { answer.handle(.leaveTypingUp) },
                    onLeaveTextDown: { answer.handle(.leaveTypingDown) }
                )
                .id(option.index)
                .onTapGesture { answer.clickOption(at: position) }
            }
        }
        .padding(.horizontal, 6)
    }

    @ViewBuilder
    private func bottomBar(_ card: AnswerCard) -> some View {
        if let form = card.form { formBottomBar(form) } else { singleBottomBar(card) }
    }

    /// Progress while the questions go out, the exact report when the batch stopped, else "N of M answered" and Submit.
    private func formBottomBar(_ form: AnswerFormState) -> some View {
        HStack(spacing: 10) {
            switch form.sendState {
            case .editing:
                Text("\(form.answeredCount) of \(form.form.questions.count) answered")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button("Submit", action: { answer.pressSend() })
                    .disabled(!form.canSubmit)
            case .sending(let question):
                ProgressView().controlSize(.small)
                Text("Sending \(question + 1) of \(form.form.questions.count)…")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            case .stopped:
                Text(form.report ?? "")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.red)
                    .lineLimit(6)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
                Button("Close", action: { answer.handle(.escape) })
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 6)
        .frame(minHeight: AgentPanelMetrics.answerBottomBarHeight)
        .background(Color.primary.opacity(0.04))
    }

    private func singleBottomBar(_ card: AnswerCard) -> some View {
        HStack(spacing: 10) {
            if let errorText = card.state.errorText {
                Text(errorText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button(sendTitle(card.state.question), action: { answer.pressSend() })
                .disabled(card.state.readyChoice == nil)
        }
        .padding(.horizontal, 18)
        .frame(minHeight: AgentPanelMetrics.answerBottomBarHeight)
        .background(Color.primary.opacity(0.04))
    }

    private func sendTitle(_ question: AnswerableQuestion) -> String {
        question.isMultiSelect ? "Submit" : "Send"
    }
}
